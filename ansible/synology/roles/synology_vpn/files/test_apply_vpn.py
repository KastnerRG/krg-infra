"""Unit tests for apply_vpn.py — run with: pytest (no DSM needed)."""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_vpn as m  # noqa: E402

# A live Settings.Config object keyed by the CURRENT best-known OUT_KEYS, with
# the values DSM actually ships (see the module docstring): 10.8.0.0/24, 5
# clients, comp-lzo ON, LAN access off.
LIVE = {
    m.OUT_KEYS["enabled"]: False,
    m.OUT_KEYS["port"]: 1194,
    m.OUT_KEYS["protocol"]: "udp",
    m.OUT_KEYS["subnet"]: "10.8.0.0",
    m.OUT_KEYS["netmask"]: "255.255.255.0",
    m.OUT_KEYS["max_connections"]: 5,
    m.OUT_KEYS["allow_lan"]: False,
    m.OUT_KEYS["push_dns"]: False,
    m.OUT_KEYS["ipv6"]: False,
    m.OUT_KEYS["cipher"]: "AES-256-CBC",
    m.OUT_KEYS["auth_digest"]: "SHA512",
    m.OUT_KEYS["compression"]: True,
    m.OUT_KEYS["tls_auth"]: False,
    m.OUT_KEYS["duplicate_cn"]: True,
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
    "--netmask",
    "255.255.255.0",
    "--max-connections",
    "20",
    "--allow-lan",
    "false",
    "--push-dns",
    "false",
    "--ipv6",
    "false",
    "--cipher",
    "AES-256-GCM",
    "--auth-digest",
    "SHA512",
    "--compression",
    "false",
    "--tls-auth",
    "true",
    "--duplicate-cn",
    "true",
]


def _factory(live, err=None):
    captured = []

    def fake(api, *params):
        if "method=load" in params:
            if err is not None:
                return {"success": False, "error": {"code": err}}
            return {"success": True, "data": dict(live)}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_openvpn_pushes_full_object_on_drift(monkeypatch, capsys):
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(SPEC_ARGS)
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    _, params = captured[0]
    joined = " ".join(params)
    assert "method=apply" in joined
    # full-object push: unchanged keys ride along, not just the drifted ones
    assert len(captured[0][1]) >= len(LIVE)


def test_openvpn_kills_comp_lzo_and_moves_subnet(monkeypatch, capsys):
    """The two drift items that matter: DSM ships comp-lzo ON (VORACLE) and
    10.8.0.0/24 (collides with client home LANs)."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    assert "{}=false".format(m.OUT_KEYS["compression"]) in joined
    assert '{}="10.90.24.0"'.format(m.OUT_KEYS["subnet"]) in joined
    drifted = json.loads(capsys.readouterr().out.split(" ", 1)[1])
    assert m.OUT_KEYS["compression"] in drifted
    assert m.OUT_KEYS["subnet"] in drifted


def test_openvpn_no_change_when_converged(monkeypatch, capsys):
    converged = dict(LIVE)
    converged.update(
        {
            m.OUT_KEYS["enabled"]: True,
            m.OUT_KEYS["subnet"]: "10.90.24.0",
            m.OUT_KEYS["max_connections"]: 20,
            m.OUT_KEYS["cipher"]: "AES-256-GCM",
            m.OUT_KEYS["compression"]: False,
            m.OUT_KEYS["tls_auth"]: True,
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


def test_openvpn_stopped_package_gives_actionable_error(monkeypatch, capsys):
    fake, _ = _factory(LIVE, err=m.ERR_API_NOT_EXIST)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "package" in out


def test_openvpn_stale_out_keys_fails_loudly(monkeypatch, capsys):
    """A renamed DSM field must NOT silently configure nothing."""
    stale = {k: v for k, v in LIVE.items() if k != m.OUT_KEYS["compression"]}
    fake, captured = _factory(stale)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "OUT_KEYS mismatch" in out
    assert captured == []


def test_privilege_refuses_to_guess(monkeypatch, capsys):
    fake, captured = _factory({"accounts": []})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["privilege", "--groups", json.dumps(["KRG\\Domain Users"])])
    assert rc == 1
    out = capsys.readouterr().out
    assert "LIVE-ACCOUNT-OBJECT" in out and "FAIL" in out
    assert captured == []


def test_privilege_rejects_empty_groups(monkeypatch, capsys):
    assert m.main(["privilege", "--groups", "[]"]) == 1
    assert capsys.readouterr().out.startswith("FAIL")


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
    "AES-256-GCM",
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


def test_package_starts_when_stopped(monkeypatch, capsys):
    calls = []

    class R:
        def __init__(self, rc, out=""):
            self.returncode, self.stdout, self.stderr = rc, out, ""

    def fake_run(cmd):
        calls.append(cmd)
        if "status" in cmd:
            return R(0, '{"package":"VPNCenter","status":"stop"}')
        return R(0)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    assert any("start" in c for c in calls)


def test_package_no_change_when_running(monkeypatch, capsys):
    class R:
        def __init__(self, rc, out=""):
            self.returncode, self.stdout, self.stderr = rc, out, ""

    monkeypatch.setattr(m, "_run", lambda cmd: R(0, '{"status":"start"}'))
    assert m.main(["package"]) == 0
    assert "OK no-change" in capsys.readouterr().out


def test_exec_strips_line_preamble(monkeypatch):
    """synowebapi's `[Line NNN] Exec WebAPI: ... param={...}` preamble contains a
    brace; naive first-`{` scanning parses the wrong object."""

    class R:
        returncode = 0
        stdout = '[Line 295] Exec WebAPI: api=X, param={"a":1}\n{"success":true,"data":{"b":2}}'
        stderr = ""

    monkeypatch.setattr(m, "_run", lambda cmd: R())
    assert m._exec("X", "method=load") == {"success": True, "data": {"b": 2}}


class _Res:
    def __init__(self, rc, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


# Real payloads captured from DSM 7.3.2 (e4e-nas, 2026-08-16). The exit codes
# are the point: synopkg signals package STATE through rc, so rc != 0 does not
# mean "absent".
STOPPED_RC, STOPPED_OUT = (
    17,
    (
        '{"aspect":{"active":{"status":"stop","status_code":273}},'
        '"description":"Status: [273], package is stopped",'
        '"package":"VPNCenter","status":"stop"}'
    ),
)
ABSENT_RC, ABSENT_OUT = (
    255,
    (
        '{"aspect":{"active":{"status":"stop","status_code":273},'
        '"error":{"status":"non_installed","status_code":255,'
        '"status_description":"failed to locate package"}},'
        '"package":"NoSuchPkg","status":"stop"}'
    ),
)


def test_package_stopped_is_not_mistaken_for_absent(monkeypatch, capsys):
    """rc=17 means installed-but-stopped. Treating non-zero rc as 'not
    installed' made the role refuse to start the very package it exists to
    start."""
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _Res(STOPPED_RC, STOPPED_OUT) if "status" in cmd else _Res(0)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    assert any("start" in c for c in calls)


def test_package_absent_is_detected_by_error_key(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _Res(ABSENT_RC, ABSENT_OUT))
    assert m.main(["package"]) == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL") and "not installed" in out


def test_package_absent_never_attempts_start(monkeypatch):
    calls = []

    def fake_run(cmd):
        calls.append(cmd)
        return _Res(ABSENT_RC, ABSENT_OUT)

    monkeypatch.setattr(m, "_run", fake_run)
    assert m.main(["package"]) == 1
    assert not any("start" in c for c in calls)


def test_package_unparseable_status_fails_cleanly(monkeypatch, capsys):
    monkeypatch.setattr(m, "_run", lambda cmd: _Res(1, "synopkg: command not found"))
    assert m.main(["package"]) == 1
    assert "could not parse" in capsys.readouterr().out
