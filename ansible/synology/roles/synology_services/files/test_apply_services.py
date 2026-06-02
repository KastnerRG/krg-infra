"""Unit tests for apply_services.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_services as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


def test_apis_table():
    assert m.APIS == {
        "ftp":  ("SYNO.Core.FileServ.FTP", 1),
        "afp":  ("SYNO.Core.FileServ.AFP", 1),
        "snmp": ("SYNO.Core.SNMP", 1),
    }


def test_bool_helper():
    assert m._bool("true") and m._bool("yes") and m._bool("1")
    assert not (m._bool("false") or m._bool("no") or m._bool("0"))


def test_ftp_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_ftp": False, "enable_ftps": False, "ext_ip": ""}))
    rc = m.main(["ftp", "--enable-ftp", "false", "--enable-ftps", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_ftp_apply_full_object(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"enable_ftp": False, "enable_ftps": True, "ext_ip": "", "custom_port": "55536:55899"},
        set_capture=captured))
    rc = m.main(["ftp", "--enable-ftp", "false", "--enable-ftps", "false"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    api, params = captured[0]
    assert api == "SYNO.Core.FileServ.FTP" and "version=1" in params and "method=set" in params
    rest = set(params[2:])
    assert "enable_ftps=false" in rest
    assert 'custom_port="55536:55899"' in rest  # unmanaged field retained


def test_afp_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"enable_afp": True}))
    rc = m.main(["afp", "--enable", "false", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "enable_afp" in out


def test_snmp_v3_apply_with_creds(monkeypatch, capsys):
    """v3-enable WITH USM credentials → full v3 SET payload (rouser + auth + priv)."""
    captured = []
    live = {"enable_snmp": False, "enable_snmp_v1v2": False, "enable_snmp_v3": False,
            "contact": "", "location": "", "name": "", "rouser": "",
            "rocommunity": "", "node0_name": "", "node1_name": ""}
    monkeypatch.setattr(m, "_exec", _exec_factory(live, set_capture=captured))
    rc = m.main(["snmp", "--enable", "true", "--v3", "true", "--v1v2", "false",
                 "--name", "e4e-nas", "--rouser", "krg-monitor",
                 "--contact", "admin@x", "--location", "UCSD",
                 "--v3-auth-protocol", "SHA", "--v3-auth-password", "secret-auth-pw-min8",
                 "--v3-priv-protocol", "AES", "--v3-priv-password", "secret-priv-pw-min8"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    # String values are JSON-quoted on the wire (the `_args_from`
    # json.dumps fix landed 2026-06-01 to avoid synowebapi parsing IP/path
    # tokens as malformed floats). Bools and ints stay bare.
    for tok in ("enable_snmp=true", "enable_snmp_v3=true", "enable_snmp_v1v2=false",
                'name="e4e-nas"', 'rouser="krg-monitor"', 'contact="admin@x"',
                'location="UCSD"',
                'v3_auth_proto="SHA"', 'v3_auth_passwd="secret-auth-pw-min8"',
                'v3_priv_proto="AES"', 'v3_priv_passwd="secret-priv-pw-min8"'):
        assert tok in rest, "missing token: " + tok


def test_snmp_v3_soft_defer_without_creds(monkeypatch, capsys):
    """v3-enable WITHOUT USM creds AND v1v2 off → soft-defer EVERYTHING:
    the whole desired dict clears so the role reports OK no-change with
    a WARN. Validated 2026-05-31 against live e4e-nas: when the SNMP
    daemon is off, DSM silently drops metadata changes (contact /
    location / name) too — pushing them produced a false-positive
    CHANGED every run while nothing actually persisted. Everything
    converges in one shot once snmp_v3_*_password lands in
    secrets-syno.yml.
    """
    captured = []
    live = {"enable_snmp": False, "enable_snmp_v1v2": False, "enable_snmp_v3": False,
            "contact": "", "location": "", "name": "", "rouser": "",
            "rocommunity": "", "node0_name": "", "node1_name": ""}
    monkeypatch.setattr(m, "_exec", _exec_factory(live, set_capture=captured))
    rc = m.main(["snmp", "--enable", "true", "--v3", "true", "--v1v2", "false",
                 "--name", "e4e-nas", "--rouser", "krg-monitor",
                 "--contact", "admin@x", "--location", "UCSD"])
    assert rc == 0
    out_err = capsys.readouterr()
    # No SET attempted at all — apply_service sees empty desired → no drift
    assert "OK no-change" in out_err.out
    # BOTH defers WARN on stderr — the v3 cred reason + the metadata-also-deferred reason
    assert "enable_snmp_v3=true deferred" in out_err.err
    assert "enable_snmp=true ALSO deferred" in out_err.err
    assert "Metadata" in out_err.err  # operator visibility on the metadata defer
    # No SET captured (apply_service short-circuits when desired is empty)
    assert captured == [], "no SET should fire when daemon is deferred: " + str(captured)


def test_snmp_v3_defer_keeps_enable_when_v1v2_on(monkeypatch, capsys):
    """v3-enable without creds BUT v1v2 ON → only v3 is deferred; daemon
    still has a working protocol (v1v2), so enable_snmp=true goes through."""
    captured = []
    live = {"enable_snmp": False, "enable_snmp_v1v2": False, "enable_snmp_v3": False,
            "contact": "", "location": "", "name": "", "rouser": "",
            "rocommunity": "", "node0_name": "", "node1_name": ""}
    monkeypatch.setattr(m, "_exec", _exec_factory(live, set_capture=captured))
    rc = m.main(["snmp", "--enable", "true", "--v3", "true", "--v1v2", "true",
                 "--name", "e4e-nas", "--rouser", "krg-monitor"])
    assert rc == 0
    out_err = capsys.readouterr()
    assert "enable_snmp_v3=true deferred" in out_err.err
    assert "enable_snmp=true ALSO deferred" not in out_err.err
    rest = set(captured[0][1][2:])
    assert "enable_snmp_v3=true" not in rest
    assert "enable_snmp=true" in rest
    assert "enable_snmp_v1v2=true" in rest


def test_snmp_v3_disabled_ignores_creds(monkeypatch, capsys):
    """If spec says v3 OFF, creds (even if supplied from secrets) MUST NOT
    leak into the SET payload — they're irrelevant + would confuse DSM."""
    captured = []
    live = {"enable_snmp": False, "enable_snmp_v3": False, "enable_snmp_v1v2": False,
            "contact": "", "location": "", "name": "", "rouser": "",
            "rocommunity": "", "node0_name": "", "node1_name": ""}
    monkeypatch.setattr(m, "_exec", _exec_factory(live, set_capture=captured))
    rc = m.main(["snmp", "--enable", "true", "--v3", "false", "--v1v2", "true",
                 "--name", "e4e-nas",
                 "--v3-auth-password", "leftover-from-secrets",
                 "--v3-priv-password", "leftover-from-secrets"])
    assert rc == 0
    capsys.readouterr()
    rest = set(captured[0][1][2:])
    assert "enable_snmp_v3=false" in rest
    assert not any(t.startswith("v3_") for t in rest), \
        "v3 cred fields must not be sent when v3 is disabled: " + str(rest)


def test_snmp_fail_on_unsuccessful_set(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"enable_snmp": False}, "success": True}
        return {"success": False, "error": {"code": 2001}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["snmp", "--enable", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
