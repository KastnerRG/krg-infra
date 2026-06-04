"""Unit tests for drift_detector.py — run with: pytest (needs pyyaml; no DSM).

Fixtures use the real DSM output shapes captured on the rig: synowebapi GET/load JSON
(with the `[Line N]` preamble), `synoshare --enum` lists, and `--list_acl` text.
"""
import json
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(__file__))
import drift_detector as d  # noqa: E402


def _webapi_lines(data):
    """Mimic an exporter snapshot's *_raw: the synowebapi preamble + pretty JSON, as lines."""
    obj = {"data": data, "httpd_restart": False, "success": True}
    return ["[Line 1] Exec WebAPI:  api=X, method=get, param={}"] + json.dumps(obj, indent=3).splitlines()


RULE = {"client": "fab", "privilege": "rw", "root_squash": "root", "async": False,
        "insecure": False, "crossmnt": True,
        "security_flavor": {"sys": True, "kerberos": False,
                            "kerberos_integrity": False, "kerberos_privacy": False}}

ACL_LINES = ["\t ACL RW List .....[@maya,bob]", "\t ACL RO List .....[]", "\t ACL NA List .....[]"]


# --- parsers --------------------------------------------------------------------
def test_parse_enum_shares_and_groups():
    assert d.parse_enum(["Share Enum Arguments: ALL", "3 Listed:", "maya", "admin", "bom_aws"]) \
        == ["maya", "admin", "bom_aws"]
    assert d.parse_enum(["0 Listed:"]) == []
    assert d.parse_enum(["4 Group Listed:", "administrators", "users"]) == ["administrators", "users"]


def test_webapi_data_strips_preamble():
    assert d.webapi_data(_webapi_lines({"enable_nfs": True})) == {"enable_nfs": True}


def test_parse_list_acl():
    t = d.parse_list_acl("\n".join(ACL_LINES))
    assert t["RW"] == {"@maya", "bob"} and t["RO"] == set() and t["NA"] == set()


# --- diffs ----------------------------------------------------------------------
def test_diff_shares_missing_extra_and_auto_ignored():
    spec = {"shares": [{"name": "maya"}, {"name": "admin"}]}
    snap = {"shares_raw": ["1 Listed:", "maya", "homes", "rogue"]}
    out = d.diff_shares(spec, snap)
    by = {(x["key"], x["live"]) for x in out}
    assert ("admin", "absent") in by        # in spec, not live -> missing
    assert ("rogue", "present") in by        # live, not spec -> unmanaged extra
    assert not any(x["key"] == "homes" for x in out)  # AUTO_SHARES ignored


def test_diff_smb_drift_and_clean():
    spec = {"smb": {"enable": True, "min_protocol": "SMB3", "max_protocol": "SMB3",
                    "server_signing": True, "ntlmv1_auth": False}}
    drift_snap = {"smb_raw": _webapi_lines({"enable_samba": True, "smb_min_protocol": 1,
                                            "smb_max_protocol": 3, "enable_server_signing": 0,
                                            "enable_ntlmv1_auth": False})}
    assert {x["key"] for x in d.diff_smb(spec, drift_snap)} == {"smb_min_protocol", "enable_server_signing"}
    clean = {"smb_raw": _webapi_lines({"enable_samba": True, "smb_min_protocol": 3,
                                       "smb_max_protocol": 3, "enable_server_signing": 1,
                                       "enable_ntlmv1_auth": False})}
    assert d.diff_smb(spec, clean) == []


def test_diff_nfs_global_and_rules():
    spec = {"nfs": {"enable": True, "nfsv4": True, "v4_domain": ""},
            "exports": [{"share": "s", "rules": [RULE]}]}
    snap = {"nfs_global_raw": _webapi_lines({"enable_nfs": False, "enable_nfs_v4": True, "nfs_v4_domain": ""}),
            "nfs_rules_raw": [{"share": "s", "load": _webapi_lines({"rule": []})}]}
    keys = {x["key"] for x in d.diff_nfs(spec, snap)}
    assert "global.enable_nfs" in keys and "rules.s" in keys

    clean = {"nfs_global_raw": _webapi_lines({"enable_nfs": True, "enable_nfs_v4": True, "nfs_v4_domain": ""}),
             "nfs_rules_raw": [{"share": "s", "load": _webapi_lines({"rule": [RULE]})}]}
    assert d.diff_nfs(spec, clean) == []


def test_diff_acls():
    spec = {"acls": [{"share": "maya", "grants": [{"group": "maya", "access": "rw"}]}]}
    snap = {"share_acls": [{"share": "maya", "list_acl": ACL_LINES}]}  # @maya,bob live vs @maya desired
    out = d.diff_acls(spec, snap)
    assert len(out) == 1 and out[0]["key"] == "maya.RW"
    assert set(out[0]["live"]) == {"@maya", "bob"} and out[0]["desired"] == ["@maya"]


# --- end-to-end run() + metrics -------------------------------------------------
def _write_specs(spec_dir, **files):
    base = {"shares.yml": {}, "smb-globals.yml": {}, "nfs-exports.yml": {}, "acls.yml": {}}
    base.update(files)
    for name, data in base.items():
        (spec_dir / name).write_text(yaml.safe_dump(data))


def test_run_reports_per_resource_and_metrics(tmp_path):
    spec_dir = tmp_path / "spec"; spec_dir.mkdir()
    snap_dir = tmp_path / "snap"; snap_dir.mkdir()
    _write_specs(spec_dir,
                 **{"shares.yml": {"shares": [{"name": "maya"}]},
                    "smb-globals.yml": {"smb": {"min_protocol": "SMB3", "max_protocol": "SMB3",
                                                "server_signing": True, "ntlmv1_auth": False, "enable": True}},
                    "acls.yml": {"acls": []}})
    (snap_dir / "e4e-nas-shares.yml").write_text(yaml.safe_dump({"shares_raw": ["1 Listed:", "maya", "homes"]}))
    (snap_dir / "e4e-nas-smb.yml").write_text(yaml.safe_dump(
        {"smb_raw": _webapi_lines({"enable_samba": True, "smb_min_protocol": 2, "smb_max_protocol": 3,
                                   "enable_server_signing": 1, "enable_ntlmv1_auth": False})}))

    results, drifts = d.run(str(spec_dir), str(snap_dir), "e4e-nas")
    assert results["shares"] == "ok"   # maya present, homes auto-ignored
    assert results["smb"] == "drift"   # min protocol 2 != 3
    assert results["nfs"] == "ok"      # empty spec -> nothing to enforce
    assert results["acls"] == "ok"     # acls: [] -> nothing

    prom = d.render_prometheus("e4e-nas", results, drifts)
    assert 'krg_synology_drift{host="e4e-nas",resource="smb"} 1' in prom
    assert 'krg_synology_drift{host="e4e-nas",resource="shares"} 0' in prom
    assert 'krg_synology_drift_check_success{host="e4e-nas"} 1' in prom


def test_missing_snapshot_is_check_failure(tmp_path):
    spec_dir = tmp_path / "spec"; spec_dir.mkdir()
    snap_dir = tmp_path / "snap"; snap_dir.mkdir()
    _write_specs(spec_dir, **{"shares.yml": {"shares": [{"name": "maya"}]}})  # but no shares snapshot
    results, _ = d.run(str(spec_dir), str(snap_dir), "e4e-nas")
    assert results["shares"] == "no-snapshot"
    assert 'krg_synology_drift_check_success{host="e4e-nas"} 0' in d.render_prometheus("e4e-nas", results, [])


def test_main_exit_codes(tmp_path, capsys):
    spec_dir = tmp_path / "spec"; spec_dir.mkdir()
    snap_dir = tmp_path / "snap"; snap_dir.mkdir()
    _write_specs(spec_dir, **{"shares.yml": {"shares": [{"name": "maya"}]}})
    (snap_dir / "e4e-nas-shares.yml").write_text(yaml.safe_dump({"shares_raw": ["1 Listed:", "maya"]}))
    argv = ["--spec-dir", str(spec_dir), "--snapshot-dir", str(snap_dir), "--host", "e4e-nas"]
    assert d.main(argv) == 0                                   # clean
    capsys.readouterr()

    (snap_dir / "e4e-nas-shares.yml").write_text(yaml.safe_dump({"shares_raw": ["0 Listed:"]}))
    assert d.main(argv) == 1                                   # maya now missing -> drift
    capsys.readouterr()

    os.remove(snap_dir / "e4e-nas-shares.yml")
    assert d.main(argv) == 2                                   # no snapshot -> error
