"""Unit tests for apply_ad.py — run with: pytest (no DSM needed).

DSM 7.3 surface (validated 2026-06-01 on e4e-nas after the cable swap):
  - SYNO.Core.Directory.Domain.Join doesn't exist (returns err 102)
  - The join check + the join action BOTH happen on SYNO.Core.Directory.Domain
  - `enable_domain` (bool) on the GET is the joined-state signal
  - The SET on a joined NAS accepts realm/domain_name/server_address/server_ip/ou
  - idmap_* / allowed_groups / admin_groups are NOT on this API surface
    (they live on winbind config / a separate API; deferred)
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_ad as m  # noqa: E402


def _factory(live):
    """Build a fake _exec that returns `live[api]["get"]` data for GETs and
    records (api, params) tuples for SETs. SETs return `live[api].get("set")`
    or `{"success": True}` by default."""
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return live.get(api, {}).get("set", {"success": True})

    return fake, captured


# --- domain-config -----------------------------------------------------------
# Joined-state GET shape DSM 7.3 returns. Note: no idmap/allowed_groups —
# those aren't fields on this API (deferred in apply_ad.py).
_JOINED_GET = {
    "enable_domain":  True,
    "realm":          "KRG.LOCAL",
    "domain_name":    "krg.local",
    "server_address": "krg-ldap.krg.local",
    "server_ip":      "137.110.161.109",
    "ou":             "OU=NAS,OU=Hosts,DC=krg,DC=local",
}


def _argv_domain_config(**overrides):
    base = {
        "realm": "KRG.LOCAL", "domain": "krg.local",
        "dc_host": "krg-ldap.krg.local", "dc_ip": "137.110.161.109",
        "ou": "OU=NAS,OU=Hosts,DC=krg,DC=local",
        # Below 5 are accepted but NOT pushed (deferred — no matching field
        # on Directory.Domain.set). Keep on argv so the role contract holds.
        "idmap_mode": "rid",
        "idmap_uid_range": "10000-2000000", "idmap_gid_range": "10000-2000000",
        "allowed_groups": json.dumps(["Domain Admins"]),
        "admin_groups": json.dumps(["Domain Admins"]),
    }
    base.update(overrides)
    argv = ["domain-config"]
    for k, v in base.items():
        argv += ["--" + k.replace("_", "-"), str(v)]
    return argv


def test_domain_no_change(monkeypatch, capsys):
    """Joined state with matching live config → OK no-change. The
    deferred-fields INFO line goes to stderr (operator visibility)."""
    fake, captured = _factory({m.DOMAIN_API: {"get": dict(_JOINED_GET)}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    out_err = capsys.readouterr()
    assert rc == 0 and "OK no-change" in out_err.out
    assert "idmap" in out_err.err  # deferred-fields INFO surfaces on stderr
    assert not any("method=set" in p for a, p in captured)


def test_domain_unjoined_short_circuits_to_no_change(monkeypatch, capsys):
    """When DSM reports `enable_domain: false`, do_domain_config short-circuits
    to OK no-change with a WARN. Pre-join SETs silently drop the fields
    (validated 2026-05-31 on live e4e-nas), which made the role report
    false-positive CHANGED every run."""
    fake, captured = _factory({m.DOMAIN_API: {"get": {"enable_domain": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    out_err = capsys.readouterr()
    assert rc == 0
    assert "OK no-change" in out_err.out and "deferred" in out_err.out
    assert "not joined" in out_err.err
    assert not any("method=set" in p for a, p in captured)


def test_domain_drift_post_join_defers_without_creds(monkeypatch, capsys):
    """Post-join, Directory.Domain.set ALWAYS requires creds (`username`)
    even for config-only updates (validated 2026-06-01: synolog says
    "cannot get the paramter: username" on the SET). do_domain_config has
    no password in its CLI, so it must defer drift with a WARN — operator
    re-runs with `-e ad_join_password='<pass>'` so do_join re-binds the
    join + config in one shot."""
    live = dict(_JOINED_GET)
    live["server_address"] = "krg-ad.krg.local"  # drift: live vs spec
    fake, captured = _factory({m.DOMAIN_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    assert rc == 0
    out_err = capsys.readouterr()
    # No SET attempted — drift detected, deferred with WARN
    assert not any("method=set" in p for a, p in captured)
    assert "OK no-change" in out_err.out and "deferred" in out_err.out
    assert "creds" in out_err.err.lower()
    assert "ad_join_password" in out_err.err  # WARN points operator at the fix


# --- test-join (read-only) --------------------------------------------------
def test_test_join_joined_via_enable_domain(monkeypatch, capsys):
    """JOINED detection now uses Domain.get → data.enable_domain
    (Domain.Join.test is err 102 on DSM 7.3 — that API namespace doesn't exist)."""
    fake, _ = _factory({m.DOMAIN_API: {"get": dict(_JOINED_GET)}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["test-join"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("JOINED")
    assert "krg.local" in out  # data.domain_name


def test_test_join_not_joined_via_enable_domain(monkeypatch, capsys):
    """enable_domain=false → NOT-JOINED (the role's join task fires)."""
    fake, _ = _factory({m.DOMAIN_API: {"get": {"enable_domain": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["test-join"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("NOT-JOINED")


def test_test_join_exec_failure_is_not_joined(monkeypatch, capsys):
    """Network/permission error → NOT-JOINED (safer to retry join than skip)."""
    def raises(*_):
        raise RuntimeError("no API")
    monkeypatch.setattr(m, "_exec", raises)
    rc = m.main(["test-join"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("NOT-JOINED")


# --- join -------------------------------------------------------------------
def _argv_join(**overrides):
    base = {
        "realm": "KRG.LOCAL", "domain": "krg.local",
        "dc_host": "krg-ldap.krg.local", "dc_ip": "137.110.161.109",
        "ou": "OU=NAS,OU=Hosts,DC=krg,DC=local",
        "join_user": "Administrator", "join_password": "secret",
    }
    base.update(overrides)
    argv = ["join"]
    for k, v in base.items():
        argv += ["--" + k.replace("_", "-"), str(v)]
    return argv


def test_join_success_uses_domain_api_with_username_field(monkeypatch, capsys):
    """Join goes through Directory.Domain.set (not the dead .Join namespace)
    with the field shape DSM 7.3 demands — `username` (not `user`),
    `domain_name` lowercase, full DC info, enable_domain=true."""
    fake, captured = _factory({m.DOMAIN_API: {"set": {"success": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_join())
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    call = next(p for a, p in captured if a == m.DOMAIN_API)
    assert "method=set" in call
    # The DSM 7.3 field names (NOT `user` — that returns "cannot get the
    # paramter: username" from synolog).
    assert 'username="Administrator"' in call
    assert 'domain_name="krg.local"' in call
    assert 'realm="KRG.LOCAL"' in call
    assert 'server_ip="137.110.161.109"' in call
    assert "enable_domain=true" in call
    assert 'password="secret"' in call


def test_join_failure_surfaces_dsm_error(monkeypatch, capsys):
    """A non-success response (e.g. err 2618) → FAIL with the DSM payload."""
    fake, _ = _factory({m.DOMAIN_API: {"set": {"success": False, "error": {"code": 2618}}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_join(join_password="wrong"))
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")


def test_join_requires_password(monkeypatch, capsys):
    """Empty --join-password must FAIL fast without issuing the SET."""
    called = []
    monkeypatch.setattr(m, "_exec", lambda *a, **k: called.append(a) or {"success": True})
    rc = m.main(_argv_join(join_password=""))
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "join requires --join-password" in out
    assert called == [], "join must not call synowebapi when password is empty"


# --- admin-groups (Ad_Domain_Admin_Groups in /etc/synoinfo.conf) -------------
# This is the load-bearing global "AD-group → @administrators" bridge.
# Pre-reset confbkp_config_tb confirmed the key shape; webapi
# Directory.Domain.Conf.set v2/v3 with domain_admin_groups silently no-ops,
# so synosetkeyvalue is the only path that actually persists.
import subprocess  # noqa: E402  (test-local import)


class _Captured:
    def __init__(self):
        self.gets = []
        self.sets = []

    def factory(self, *, current_value=""):
        """Build a fake subprocess.run that simulates synogetkeyvalue/synosetkeyvalue."""
        def fake_run(cmd, *_, **__):
            class R:
                returncode = 0
                stderr = ""
                stdout = ""
            r = R()
            if cmd[0] == m.SYNOGETKEYVALUE:
                self.gets.append(cmd)
                r.stdout = current_value + "\n"
            elif cmd[0] == m.SYNOSETKEYVALUE:
                self.sets.append(cmd)
                # Mutate the captured value so a follow-up GET would reflect the write.
                current_value_cell[0] = cmd[3]
            return r
        current_value_cell = [current_value]
        # Surface the cell so the test can re-read post-SET if it wants.
        self.current_value_cell = current_value_cell
        return fake_run


def test_admin_groups_no_change(monkeypatch, capsys):
    """Current synoinfo.conf value already matches desired → OK no-change, no SET."""
    cap = _Captured()
    monkeypatch.setattr(subprocess, "run",
                        cap.factory(current_value="KRG\\Domain Admins,KRG\\E4E Admin"))
    rc = m.main(["admin-groups",
                 "--groups", json.dumps(["Domain Admins", "E4E Admin"]),
                 "--netbios", "KRG"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert cap.sets == [], "no-change must not call synosetkeyvalue"


def test_admin_groups_change_writes_csv_with_netbios_prefix(monkeypatch, capsys):
    """First-time SET on a fresh NAS: empty current → writes the comma-separated
    `<NETBIOS>\\<group>` list. Regression guard for the exact wire format
    (comma separator, NETBIOS prefix per group, no @-prefix, no JSON escaping —
    matches the pre-reset confbkp_config_tb value verbatim)."""
    cap = _Captured()
    monkeypatch.setattr(subprocess, "run", cap.factory(current_value=""))
    rc = m.main(["admin-groups",
                 "--groups", json.dumps(["Domain Admins", "E4E Admin"]),
                 "--netbios", "KRG"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert len(cap.sets) == 1
    set_cmd = cap.sets[0]
    assert set_cmd[1] == m.SYNOINFO_CONF
    assert set_cmd[2] == m.ADMIN_GROUPS_KEY
    # CRITICAL: format is `<NETBIOS>\<group>,<NETBIOS>\<group>` — one backslash,
    # no @-prefix, comma separator. Pre-reset confbkp showed exactly this.
    assert set_cmd[3] == "KRG\\Domain Admins,KRG\\E4E Admin", (
        "wire format must match the pre-reset confbkp shape; got " + repr(set_cmd[3]))


def test_admin_groups_check_mode_writes_nothing(monkeypatch, capsys):
    """--check reports WOULD-CHANGE but never invokes synosetkeyvalue."""
    cap = _Captured()
    monkeypatch.setattr(subprocess, "run", cap.factory(current_value=""))
    rc = m.main(["admin-groups",
                 "--groups", json.dumps(["Domain Admins"]),
                 "--netbios", "KRG", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert cap.sets == [], "--check must not write"


def test_admin_groups_single_group(monkeypatch, capsys):
    """Single-group list — no trailing comma, no leading separator."""
    cap = _Captured()
    monkeypatch.setattr(subprocess, "run", cap.factory(current_value=""))
    m.main(["admin-groups",
            "--groups", json.dumps(["Domain Admins"]),
            "--netbios", "KRG"])
    capsys.readouterr()
    assert cap.sets[0][3] == "KRG\\Domain Admins"


def test_admin_groups_set_failure_returns_fail(monkeypatch, capsys):
    """synosetkeyvalue failure surfaces as FAIL, not a silent pretend-success."""
    def fake_run(cmd, *_, **__):
        class R:
            stdout = ""
            stderr = ""
        r = R()
        if cmd[0] == m.SYNOGETKEYVALUE:
            r.returncode = 0
            r.stdout = ""
            return r
        r.returncode = 1
        r.stderr = "permission denied"
        return r
    monkeypatch.setattr(subprocess, "run", fake_run)
    rc = m.main(["admin-groups",
                 "--groups", json.dumps(["Domain Admins"]),
                 "--netbios", "KRG"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


def test_admin_groups_rejects_bad_groups_json():
    """Non-list groups arg → SystemExit (argparse / SystemExit boundary)."""
    import pytest as _pt
    with _pt.raises(SystemExit):
        m.main(["admin-groups", "--groups", '"not a list"', "--netbios", "KRG"])
