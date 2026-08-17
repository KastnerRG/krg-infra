"""Unit tests for apply_vpn.py — run with: pytest (no DSM needed)."""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_vpn as m  # noqa: E402

# The REAL Settings.Config payload, captured from e4e-nas (DSM 7.3.2,
# VPNCenter 1.4.10-2984, 2026-08-16). Note the mixed types — serv_enable is a
# JSON bool while comp_enable/push_route_enable/tls_auth_key are 0/1 ints. That
# asymmetry is the idempotence trap these tests exist to pin down.
LIVE = {
    "auth_conn": 3,
    "authentication": "SHA512",
    "comp_enable": 1,
    "enable_ipv6_server": 0,
    "encryption": "AUTO",
    "ipv6_prefix": "",
    "mssfix_value": 1450,
    "no_inter_cert": False,
    "port": 1194,
    "protocol": "udp",
    "push_route_enable": 0,
    "serv_enable": False,
    "serv_ip": "10.8.0.0",
    "serv_range": 5,
    "serv_run": False,
    "serv_type": 3,
    "tls_auth_key": 0,
    "user_conf": False,
    "verify_server_cn": 0,
}

SPEC_ARGS = [
    "openvpn",
    "--enable",
    "true",
    "--port",
    "1194",
    "--protocol",
    "udp",
    "--subnet",
    "10.90.24.0",
    "--max-connections",
    "20",
    "--allow-lan",
    "false",
    "--ipv6",
    "false",
    "--cipher",
    "AES-256-CBC",
    "--auth-digest",
    "SHA512",
    "--compression",
    "false",
    "--tls-auth",
    "true",
]


def _factory(live, err=None):
    captured = []

    def fake(api, *params):
        if "method=load" in params:
            if err is not None:
                return {"success": False, "error": {"code": err}}
            return {"success": True, "data": {"items": dict(live)}}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_load_unwraps_data_items(monkeypatch):
    """`load` returns {"data": {"items": {...}}} — reading data directly yields
    a dict of one useless key."""
    fake, _ = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    items, err = m._load(m.CONFIG_API)
    assert err is None
    assert items["serv_ip"] == "10.8.0.0"


def test_load_sends_mandatory_serv_type(monkeypatch):
    """Omitting serv_type is what produced err 600 for a day."""
    seen = {}

    def fake(api, *params):
        seen["params"] = params
        return {"success": True, "data": {"items": dict(LIVE)}}

    monkeypatch.setattr(m, "_exec", fake)
    m._load(m.CONFIG_API)
    assert 'serv_type="openvpn"' in seen["params"]


def test_openvpn_pushes_full_object_on_drift(monkeypatch, capsys):
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    _, params = captured[0]
    joined = " ".join(params)
    assert "method=apply" in joined and 'serv_type="openvpn"' in joined
    # full-object push: untouched fields ride along (err 2001 on partial)
    assert "mssfix_value=1450" in joined and "auth_conn=3" in joined


def test_openvpn_kills_comp_lzo_and_moves_subnet(monkeypatch, capsys):
    """The two drift items that matter: DSM ships comp_enable=1 (VORACLE) and
    10.8.0.0/24, which collides with client home LANs."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    assert "comp_enable=0" in joined
    assert 'serv_ip="10.90.24.0"' in joined
    assert "serv_range=20" in joined
    drifted = json.loads(capsys.readouterr().out.split(" ", 1)[1])
    assert "comp_enable" in drifted and "serv_ip" in drifted


def test_int01_flags_are_pushed_as_ints_not_bools(monkeypatch):
    """comp_enable/tls_auth_key/push_route_enable are 0/1 ints in DSM. Pushing
    JSON booleans is accepted but never compares equal again, so the role would
    report CHANGED on every single run and never converge."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    for flag in ("comp_enable", "tls_auth_key", "push_route_enable", "enable_ipv6_server"):
        assert "%s=true" % flag not in joined and "%s=false" % flag not in joined
    assert "tls_auth_key=1" in joined


def test_serv_enable_stays_a_real_bool(monkeypatch):
    """...while serv_enable genuinely IS a bool. Coercing everything one way
    would just move the bug."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    assert "serv_enable=true" in " ".join(captured[0][1])


def test_openvpn_converges_to_no_change(monkeypatch, capsys):
    """Second run against the state the first run produced must be a no-op —
    the property that proves the type coercion is right."""
    converged = dict(LIVE)
    converged.update(
        {
            "serv_enable": True,
            "serv_ip": "10.90.24.0",
            "serv_range": 20,
            "encryption": "AES-256-CBC",
            "comp_enable": 0,
            "tls_auth_key": 1,
        }
    )
    fake, captured = _factory(converged)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert captured == []


def test_openvpn_check_mode_does_not_apply(monkeypatch, capsys):
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS + ["--check"]) == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert captured == []


def test_openvpn_refuses_allow_lan(monkeypatch, capsys):
    """allow_lan=true would make the NAS a router onto the campus subnet. The
    guard must fire BEFORE any API call."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    args = list(SPEC_ARGS)
    args[args.index("--allow-lan") + 1] = "true"
    assert m.main(args) == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "allow_lan" in out
    assert captured == []


def test_err_600_blames_parameters_not_transport(monkeypatch, capsys):
    """600 cost a day by being read as 'needs a web session'. The message must
    point at the real cause."""
    fake, _ = _factory(LIVE, err=m.ERR_BAD_PARAMS)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 1
    out = capsys.readouterr().out
    assert "serv_type" in out and "NOT a" in out


def test_err_102_points_at_the_stopped_package(monkeypatch, capsys):
    fake, _ = _factory(LIVE, err=m.ERR_API_NOT_EXIST)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 1
    assert "package" in capsys.readouterr().out


def test_stale_field_map_fails_loudly(monkeypatch, capsys):
    stale = {k: v for k, v in LIVE.items() if k != "comp_enable"}
    fake, captured = _factory(stale)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "field mismatch" in out
    assert captured == []


def test_unsupported_spec_keys_are_declared():
    """netmask/push_dns/duplicate_cn/tls_min_version have no DSM equivalent.
    Recorded so nobody adds them to FIELDS expecting them to apply."""
    for key in m.UNSUPPORTED:
        assert key not in m.FIELDS


def test_privilege_refuses_to_guess(monkeypatch, capsys):
    fake, captured = _factory({"accounts": []})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["privilege", "--groups", json.dumps(["KRG\\Domain Users"])])
    assert rc == 1
    out = capsys.readouterr().out
    assert "LIVE-ACCOUNT-OBJECT" in out and "FAIL" in out
    assert captured == []


def test_privilege_rejects_empty_groups(capsys):
    assert m.main(["privilege", "--groups", "[]"]) == 1
    assert capsys.readouterr().out.startswith("FAIL")


def test_dump_never_returns_nonzero(monkeypatch, capsys):
    def boom(api, *params):
        raise RuntimeError("boom")

    monkeypatch.setattr(m, "_exec", boom)
    assert m.main(["dump"]) == 0
    out = capsys.readouterr().out
    assert "dump-error" in out
    assert "FAIL" not in out and "CHANGED" not in out


def test_dump_prints_key_names_and_redacts(monkeypatch, capsys):
    secretish = dict(LIVE)
    secretish.update({"ovpn_ca_cert": "-----BEGIN CERT", "admin_password": "hunter2"})
    fake, _ = _factory(secretish)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["dump"]) == 0
    out = capsys.readouterr().out
    assert "SCHEMA" in out and "serv_ip" in out
    assert "hunter2" not in out and "BEGIN CERT" not in out
    assert "<redacted>" in out
    assert "admin_password" in out  # key NAMES survive — the point of a dump


def test_exec_strips_line_preamble(monkeypatch):
    """synowebapi's `[Line NNN] Exec WebAPI: ... param={...}` preamble contains
    a brace; naive first-`{` scanning parses the wrong object."""

    class R:
        returncode = 0
        stdout = '[Line 295] Exec WebAPI: api=X, param={"a":1}\n{"success":true,"data":{"b":2}}'
        stderr = ""

    monkeypatch.setattr(m, "_run", lambda cmd: R())
    assert m._exec("X", "method=load") == {"success": True, "data": {"b": 2}}


PUBLISH_ARGS = [
    "publish",
    "--host",
    "e4e-nas.ucsd.edu",
    "--vpn-ip",
    "10.90.24.1",
    "--port",
    "1194",
    "--protocol",
    "udp",
    "--cipher",
    "AES-256-CBC",
    "--auth-digest",
    "SHA512",
    "--tls-auth",
    "true",
]


def _stub_keys(monkeypatch, tmp_path):
    ca = tmp_path / "ca.crt"
    ta = tmp_path / "ta.key"
    ca.write_text("-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n")
    ta.write_text(
        "-----BEGIN OpenVPN Static key V1-----\nTA\n-----END OpenVPN Static key V1-----\n"
    )
    monkeypatch.setattr(m, "CA_CRT", str(ca))
    monkeypatch.setattr(m, "TA_KEY", str(ta))


def test_publish_embeds_ca_and_ta(monkeypatch, tmp_path, capsys):
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "installers" / "e4e-nas.ovpn"
    dest.parent.mkdir()
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    body = dest.read_text()
    assert "<ca>" in body and "<tls-auth>" in body and "key-direction 1" in body
    assert "remote e4e-nas.ucsd.edu 1194" in body
    # split tunnel: redirect-gateway must never be active in a shipped config
    assert "\nredirect-gateway" not in body


def test_publish_omits_tls_auth_when_off(monkeypatch, tmp_path):
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "e4e-nas.ovpn"
    args = list(PUBLISH_ARGS)
    args[args.index("--tls-auth") + 1] = "false"
    assert m.main(args + ["--dest", str(dest)]) == 0
    body = dest.read_text()
    assert "<tls-auth>" not in body and "<ca>" in body


def test_publish_idempotent(monkeypatch, tmp_path, capsys):
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    capsys.readouterr()
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    assert "OK no-change" in capsys.readouterr().out


def test_publish_check_mode_writes_nothing(monkeypatch, tmp_path, capsys):
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest), "--check"]) == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not dest.exists()


def test_publish_fails_on_missing_share(monkeypatch, tmp_path, capsys):
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "no-such-share" / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 1
    assert "does not exist" in capsys.readouterr().out


class _Res:
    def __init__(self, rc, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


STOPPED_RC, STOPPED_OUT = (
    17,
    (
        '{"aspect":{"active":{"status":"stop","status_code":273}},'
        '"package":"VPNCenter","status":"stop"}'
    ),
)
ABSENT_RC, ABSENT_OUT = (
    255,
    (
        '{"aspect":{"active":{"status":"stop","status_code":273},'
        '"error":{"status":"non_installed","status_code":255}},'
        '"package":"NoSuchPkg","status":"stop"}'
    ),
)


def test_package_stopped_is_not_mistaken_for_absent(monkeypatch, capsys):
    """rc=17 means installed-but-stopped."""
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _Res(STOPPED_RC, STOPPED_OUT) if "status" in cmd else _Res(0)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    assert any("start" in c for c in calls)


def test_package_absent_never_attempts_start(monkeypatch, capsys):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _Res(ABSENT_RC, ABSENT_OUT)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 1
    assert "not installed" in capsys.readouterr().out
    assert not any("start" in c for c in calls)


RUNNING_OUT = (
    '{"aspect":{"active":{"status":"running","status_code":0}},'
    '"description":"Status: [0], package is started",'
    '"package":"VPNCenter","status":"running"}'
)


def test_package_no_change_when_running(monkeypatch, capsys):
    """DSM says "running", not "start". Guessing that sentinel made the task
    non-idempotent: CHANGED every run, plus a pointless restart."""
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _Res(0, RUNNING_OUT)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert not any("start" in c for c in calls)
