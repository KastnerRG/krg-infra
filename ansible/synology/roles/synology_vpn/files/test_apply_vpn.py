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
    assert "comp_enable=false" in joined  # bool on the wire, int on read
    assert 'serv_ip="10.90.24.0"' in joined
    assert "serv_range=20" in joined
    drifted = json.loads(capsys.readouterr().out.split(" ", 1)[1])
    assert "comp_enable" in drifted and "serv_ip" in drifted


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


# --- write contract (captured from the DSM UI's own Apply POST, 2026-08-17) ---
# `load` returns 19 fields; `apply` accepts 15, and flags flip int->bool across
# the two. Both asymmetries produced a bare err 600 with no diagnostic.


def test_apply_sends_flags_as_bools_not_ints(monkeypatch):
    """comp_enable reads back as 1 but MUST be written as true."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    assert "comp_enable=false" in joined  # spec turns it off
    assert "tls_auth_key=true" in joined  # spec turns it on
    for flag in ("comp_enable", "tls_auth_key", "push_route_enable", "enable_ipv6_server"):
        assert "%s=0" % flag not in joined and "%s=1" % flag not in joined


def test_apply_omits_read_only_fields(monkeypatch):
    """serv_run / no_inter_cert / user_conf / the integer serv_type come back
    from load but are REJECTED by apply — sending them is what caused 600."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    for field in ("serv_run", "no_inter_cert", "user_conf"):
        assert field + "=" not in joined
    # serv_type appears exactly once, as the string discriminator
    assert joined.count("serv_type=") == 1 and 'serv_type="openvpn"' in joined


def test_apply_sends_exactly_the_captured_field_set(monkeypatch):
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    sent = {p.split("=")[0] for p in captured[0][1] if "=" in p}
    sent -= {"version", "method", "serv_type"}
    assert sent == {f for f, _k in m.WRITE_FIELDS}


def test_unmanaged_write_fields_pass_through_unchanged(monkeypatch):
    """verify_server_cn / auth_conn / ipv6_prefix / mssfix_value are required by
    apply but not spec-managed: they must ride through from the loaded object."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    joined = " ".join(captured[0][1])
    assert "mssfix_value=1450" in joined and "auth_conn=3" in joined
    assert "verify_server_cn=false" in joined  # int 0 in, bool out


def test_serv_enable_is_bool_in_both_directions(monkeypatch):
    """serv_enable is the exception: a real bool on read AND write."""
    fake, captured = _factory(LIVE)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    assert "serv_enable=true" in " ".join(captured[0][1])


def test_converges_when_live_matches_spec_despite_int_flags(monkeypatch, capsys):
    """The live payload stores flags as ints while the spec thinks in bools.
    A converged box must report no-change, not CHANGED forever."""
    converged = dict(LIVE)
    converged.update(
        {
            "serv_enable": True,
            "serv_ip": "10.90.24.0",
            "serv_range": 20,
            "encryption": "AES-256-CBC",
            "comp_enable": 0,  # int, as DSM stores it
            "tls_auth_key": 1,  # int, as DSM stores it
        }
    )
    fake, captured = _factory(converged)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(SPEC_ARGS) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert captured == []


def test_service_restarts_only_when_enabled_but_down(monkeypatch, capsys):
    """Settings.Config.apply writes serv_enable but does NOT start openvpn."""
    down = dict(LIVE)
    down.update({"serv_enable": True, "serv_run": False})
    fake, _ = _factory(down)
    calls = []
    monkeypatch.setattr(m, "_exec", fake)
    monkeypatch.setattr(m, "_run", lambda cmd: calls.append(cmd) or _Res(0))
    assert m.main(["service"]) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    assert any("restart" in c for c in calls)


def test_service_is_noop_when_running(monkeypatch, capsys):
    up = dict(LIVE)
    up.update({"serv_enable": True, "serv_run": True})
    fake, _ = _factory(up)
    calls = []
    monkeypatch.setattr(m, "_exec", fake)
    monkeypatch.setattr(m, "_run", lambda cmd: calls.append(cmd) or _Res(0))
    assert m.main(["service"]) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert calls == []


def test_service_leaves_daemon_down_when_spec_disables(monkeypatch, capsys):
    """A disabled server must NOT be started — the daemon being down is the
    desired state, not drift to correct."""
    off = dict(LIVE)
    off.update({"serv_enable": False, "serv_run": False})
    fake, _ = _factory(off)
    calls = []
    monkeypatch.setattr(m, "_exec", fake)
    monkeypatch.setattr(m, "_run", lambda cmd: calls.append(cmd) or _Res(0))
    assert m.main(["service"]) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert calls == []


# --- privilege: local-account deny (captured from the UI, 2026-08-17) ---------
# Management.Account enumerates LOCAL accounts only — no AD principals exist to
# grant to, so the job is denying the locals DSM ships enabled.
ACCOUNTS = {
    "items": [
        {
            "username": "admin",
            "enable_ovpn": True,
            "enable_l2tp": True,
            "enable_pptp": True,
            "status": 2,
        },
        {
            "username": "e4e-admin",
            "enable_ovpn": True,
            "enable_l2tp": True,
            "enable_pptp": True,
            "status": 1,
        },
        {
            "username": "e4e-automation",
            "enable_ovpn": True,
            "enable_l2tp": True,
            "enable_pptp": True,
            "status": 1,
        },
        {
            "username": "guest",
            "enable_ovpn": True,
            "enable_l2tp": True,
            "enable_pptp": True,
            "status": 2,
        },
    ],
    "total": 4,
}


def _acct_factory(accounts):
    captured = []

    def fake(api, *params):
        if "method=load" in params:
            return {"success": True, "data": dict(accounts)}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_privilege_denies_every_local_account(monkeypatch, capsys):
    fake, captured = _acct_factory(ACCOUNTS)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["privilege", "--deny-local", '["all"]']) == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    payload = [p for p in captured[0][1] if p.startswith("priv=")][0]
    priv = json.loads(payload[len("priv=") :])
    assert {p["name"] for p in priv} == {"admin", "e4e-admin", "e4e-automation", "guest"}
    assert all(p["enable_ovpn"] is False for p in priv)
    assert all(p["enable_l2tp"] is False and p["enable_pptp"] is False for p in priv)


def test_privilege_uses_name_on_write_not_username(monkeypatch):
    """load returns `username`; apply takes `name`. Another read/write rename."""
    fake, captured = _acct_factory(ACCOUNTS)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["privilege", "--deny-local", '["all"]']) == 0
    priv = json.loads([p for p in captured[0][1] if p.startswith("priv=")][0][len("priv=") :])
    assert all("name" in p and "username" not in p for p in priv)
    assert all("status" not in p for p in priv)  # status is read-only


def test_privilege_can_spare_a_named_account(monkeypatch):
    fake, captured = _acct_factory(ACCOUNTS)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["privilege", "--deny-local", '["e4e-admin","guest"]']) == 0
    priv = json.loads([p for p in captured[0][1] if p.startswith("priv=")][0][len("priv=") :])
    by = {p["name"]: p for p in priv}
    assert by["e4e-admin"]["enable_ovpn"] is False
    assert by["guest"]["enable_ovpn"] is False
    assert by["admin"]["enable_ovpn"] is True  # not named -> untouched
    assert by["e4e-automation"]["enable_ovpn"] is True


def test_privilege_converges(monkeypatch, capsys):
    denied = {
        "items": [
            dict(i, enable_ovpn=False, enable_l2tp=False, enable_pptp=False)
            for i in ACCOUNTS["items"]
        ],
        "total": 4,
    }
    fake, captured = _acct_factory(denied)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["privilege", "--deny-local", '["all"]']) == 0
    assert "OK no-change" in capsys.readouterr().out
    assert captured == []


def test_privilege_check_mode_does_not_apply(monkeypatch, capsys):
    fake, captured = _acct_factory(ACCOUNTS)
    monkeypatch.setattr(m, "_exec", fake)
    assert m.main(["privilege", "--deny-local", '["all"]', "--check"]) == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert captured == []


def test_publish_check_mode_reports_no_change_when_converged(monkeypatch, tmp_path, capsys):
    """--check must not claim a change on an already-published, identical file."""
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    capsys.readouterr()
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest), "--check"]) == 0
    assert "OK no-change" in capsys.readouterr().out


# --- client CA chain (regression: the tunnel could not establish) -------------
# DSM serves the VPN with the DSM system certificate (Let's Encrypt here), so
# the client needs a chain to a ROOT. Publishing ca.crt — the intermediate
# alone — failed every client at "VERIFY ERROR: depth=2".
CHAIN = (
    "-----BEGIN CERTIFICATE-----\nYR2\n-----END CERTIFICATE-----\n"
    "-----BEGIN CERTIFICATE-----\nROOTYR\n-----END CERTIFICATE-----\n"
    "-----BEGIN CERTIFICATE-----\nX1\n-----END CERTIFICATE-----\n"
)


def test_publish_prefers_the_full_chain_bundle(monkeypatch, tmp_path):
    _stub_keys(monkeypatch, tmp_path)
    bundle = tmp_path / "ca_bundle.crt"
    bundle.write_text(CHAIN)
    monkeypatch.setattr(m, "CA_BUNDLE", str(bundle))
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    body = dest.read_text()
    assert body.count("BEGIN CERTIFICATE") >= 3  # chain, not just the leaf CA
    assert "ROOTYR" in body and "X1" in body


def test_publish_rejects_a_single_cert_bundle(monkeypatch, tmp_path, capsys):
    """A one-cert bundle means no path to a root — fail loudly rather than
    shipping a config that cannot connect."""
    _stub_keys(monkeypatch, tmp_path)
    bundle = tmp_path / "ca_bundle.crt"
    bundle.write_text("-----BEGIN CERTIFICATE-----\nONLY\n-----END CERTIFICATE-----\n")
    monkeypatch.setattr(m, "CA_BUNDLE", str(bundle))
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 1
    assert "expected a chain" in capsys.readouterr().out
    assert not dest.exists()


def test_publish_pins_the_server_identity(monkeypatch, tmp_path):
    """Trusting a PUBLIC CA means any LE-issued cert would satisfy the chain,
    so the config must also pin EKU and subject name."""
    _stub_keys(monkeypatch, tmp_path)
    monkeypatch.setattr(m, "CA_BUNDLE", str(tmp_path / "absent"))
    dest = tmp_path / "e4e-nas.ovpn"
    assert m.main(PUBLISH_ARGS + ["--dest", str(dest)]) == 0
    body = dest.read_text()
    assert "remote-cert-tls server" in body
    assert "verify-x509-name e4e-nas.ucsd.edu name" in body


# --- auth backend (regression: every AD login was "Incorrect user name") ------
# The live files as VPNCenter ships them, read off e4e-nas 2026-08-25 — still at
# their install-time mtime, which is what proved nothing had ever reconciled
# them. rad_site_def selecting `_local` is the whole bug.
SHIPPED_SITE_DEF = "$INCLUDE /var/packages/VPNCenter/etc/syno_conf/rad_site_def_local\n"
SHIPPED_NTLM = (
    'program = "/usr/local/bin/ntlm_auth --request-nt-key --domain=MYDOMAIN '
    '--username=%{mschap:User-Name} --password=%{User-Password}"\n'
)


def _stub_auth(monkeypatch, tmp_path, joined="yes", protocols="runopenvpn=yes\n", workgroup="KRG"):
    """Redirect every path cmd_auth touches into tmp_path, seeded as-shipped."""
    conf = tmp_path / "syno_conf"
    conf.mkdir()
    (conf / "rad_site_def").write_text(SHIPPED_SITE_DEF)
    (conf / "rad_ntlm_auth").write_text(SHIPPED_NTLM)
    for site in ("ad", "local", "ldap"):
        (conf / ("rad_site_def_%s" % site)).write_text("# site %s\n" % site)

    synoinfo = tmp_path / "synoinfo.conf"
    synoinfo.write_text('unique="synology_x"\ndomainjoined="%s"\n' % joined)
    smb = tmp_path / "smb.conf"
    smb.write_text("[global]\n\tworkgroup=%s\n\tsecurity=ads\n\trealm=KRG.LOCAL\n" % workgroup)
    synovpn = tmp_path / "synovpn.conf"
    synovpn.write_text(protocols)

    monkeypatch.setattr(m, "SYNO_CONF_DIR", str(conf))
    monkeypatch.setattr(m, "RAD_SITE_DEF", str(conf / "rad_site_def"))
    monkeypatch.setattr(m, "RAD_NTLM_AUTH", str(conf / "rad_ntlm_auth"))
    monkeypatch.setattr(m, "SYNOINFO_CONF", str(synoinfo))
    monkeypatch.setattr(m, "SMB_CONF", str(smb))
    monkeypatch.setattr(m, "SYNOVPN_CONF", str(synovpn))

    # A fake /proc so the stale-daemon check has a vpnauthd to look at. Its
    # dir mtime IS the process start time, so "restarting" means replacing it.
    proc = tmp_path / "proc"
    proc.mkdir(exist_ok=True)
    (proc / "100").mkdir()
    (proc / "100" / "comm").write_text("vpnauthd\n")
    monkeypatch.setattr(m, "PROC_DIR", str(proc))

    calls = []
    counter = [100]

    def fake_run(cmd, env=None):
        calls.append(cmd)
        for old in list(proc.iterdir()):
            if old.is_dir() and old.name.isdigit():
                (old / "comm").unlink()
                old.rmdir()
        counter[0] += 1
        new = proc / str(counter[0])
        new.mkdir()
        (new / "comm").write_text("vpnauthd\n")
        return _Res(0)

    monkeypatch.setattr(m, "_run", fake_run)
    return conf, calls


def test_auth_switches_the_shipped_local_site_to_ad(monkeypatch, tmp_path, capsys):
    conf, calls = _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    out = capsys.readouterr().out
    assert "CHANGED" in out
    site = (conf / "rad_site_def").read_text()
    assert site.endswith("rad_site_def_ad\n"), site
    assert "_local" not in site
    # and vpnauthd was actually bounced, or the running daemon keeps the old site
    assert any("radiusd.sh" in str(c) and "force-restart" in str(c) for c in calls), calls


def test_auth_templates_the_real_domain_over_mydomain(monkeypatch, tmp_path):
    conf, _ = _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    ntlm = (conf / "rad_ntlm_auth").read_text()
    assert "MYDOMAIN" not in ntlm
    # The xlat form, not a bare domain: it must accept BOTH `KRG\user` (Realm
    # set by rad_site_def_ad) and a bare username (falls back to the default).
    assert "--domain=%{%{Realm}:-KRG}" in ntlm
    assert "--username=%{mschap:User-Name}" in ntlm
    assert "--password=%{User-Password}" in ntlm


def test_auth_falls_back_to_the_smb_workgroup(monkeypatch, tmp_path):
    conf, _ = _stub_auth(monkeypatch, tmp_path, workgroup="OTHER")
    assert m.main(["auth", "--backend", "ad", "--domain", ""]) == 0
    assert "--domain=%{%{Realm}:-OTHER}" in (conf / "rad_ntlm_auth").read_text()


def test_auth_converges_to_no_change(monkeypatch, tmp_path, capsys):
    _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    capsys.readouterr()
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("OK no-change"), out


def test_auth_second_run_does_not_bounce_vpnauthd(monkeypatch, tmp_path):
    _, calls = _stub_auth(monkeypatch, tmp_path)
    m.main(["auth", "--backend", "ad", "--domain", "KRG"])
    before = len(calls)
    m.main(["auth", "--backend", "ad", "--domain", "KRG"])
    # A converged box must not drop live tunnels on every deploy.
    assert len(calls) == before, calls


def test_auth_check_mode_writes_nothing(monkeypatch, tmp_path, capsys):
    conf, calls = _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG", "--check"]) == 0
    out = capsys.readouterr().out
    assert "WOULD-CHANGE" in out
    assert (conf / "rad_site_def").read_text() == SHIPPED_SITE_DEF
    assert not calls


def test_auth_refuses_ad_when_the_box_is_not_joined(monkeypatch, tmp_path, capsys):
    conf, _ = _stub_auth(monkeypatch, tmp_path, joined="no")
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 1
    out = capsys.readouterr().out
    assert "FAIL" in out and "domainjoined" in out
    # It must not have half-applied: an AD site with no winbind rejects everyone,
    # which is the SAME symptom as the bug this fixes.
    assert (conf / "rad_site_def").read_text() == SHIPPED_SITE_DEF


def test_auth_rejects_an_unknown_backend(monkeypatch, tmp_path, capsys):
    _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "kerberos"]) == 1
    assert "FAIL" in capsys.readouterr().out


def test_auth_does_not_bounce_when_no_protocol_is_enabled(monkeypatch, tmp_path, capsys):
    # radiusd.sh's start branch exits 0 without starting unless a protocol is
    # on, so an unconditional force-restart would stop vpnauthd and leave it down.
    _, calls = _stub_auth(monkeypatch, tmp_path, protocols="runopenvpn=no\n")
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    assert "CHANGED" in capsys.readouterr().out
    assert not calls


def test_auth_fails_loudly_if_the_restart_fails(monkeypatch, tmp_path, capsys):
    # Files written but the daemon still on the old site == auth unchanged.
    _stub_auth(monkeypatch, tmp_path)
    monkeypatch.setattr(m, "RESTART_TIMEOUT_S", 0.0)
    monkeypatch.setattr(m, "_run", lambda cmd, env=None: _Res(1, "vpnauthd refused"))
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 1
    assert "FAIL" in capsys.readouterr().out


def test_auth_local_backend_leaves_ntlm_alone(monkeypatch, tmp_path, capsys):
    # `local` is the vendor default and is already live, so this is a no-op —
    # the point of the test is that it does not rewrite rad_ntlm_auth.
    conf, _ = _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "local"]) == 0
    assert capsys.readouterr().out.startswith("OK no-change")
    assert (conf / "rad_ntlm_auth").read_text() == SHIPPED_NTLM


def test_key_value_parses_dsm_conf_forms(tmp_path):
    p = tmp_path / "c.conf"
    p.write_text('# comment\n\tworkgroup=KRG\nfoo = "bar"\ndomainjoined="yes"\n')
    assert m._key_value(str(p), "workgroup") == "KRG"
    assert m._key_value(str(p), "foo") == "bar"
    assert m._key_value(str(p), "domainjoined") == "yes"
    assert m._key_value(str(p), "absent") is None


# --- the restart must be PROVEN, not trusted ---------------------------------
# radiusd.sh exits 0 whether it restarted vpnauthd, no-opped, or failed every
# command inside — and on the first real apply it no-opped (it calls
# `synosystemctl` unqualified, which is not on ansible's remote PATH) while the
# role reported CHANGED. These pin that down.
def _fake_proc(tmp_path, pids, comm="vpnauthd"):
    proc = tmp_path / "proc"
    proc.mkdir(exist_ok=True)
    for pid in pids:
        d = proc / str(pid)
        d.mkdir(exist_ok=True)
        (d / "comm").write_text(comm + "\n")
    (proc / "notapid").mkdir(exist_ok=True)  # must be skipped, not crashed on
    return proc


def test_pids_named_reads_proc_comm(monkeypatch, tmp_path):
    monkeypatch.setattr(m, "PROC_DIR", str(_fake_proc(tmp_path, [7, 42])))
    assert m._pids_named("vpnauthd") == [7, 42]
    assert m._pids_named("openvpn") == []


def test_restart_passes_the_syno_path(monkeypatch, tmp_path):
    # The whole bug: radiusd.sh calls `synosystemctl` unqualified.
    proc = _fake_proc(tmp_path, [11])
    monkeypatch.setattr(m, "PROC_DIR", str(proc))
    seen = {}

    def fake_run(cmd, env=None):
        seen["cmd"], seen["env"] = cmd, env
        (proc / "22").mkdir()
        (proc / "22" / "comm").write_text("vpnauthd\n")
        for stale in proc.glob("11"):
            (stale / "comm").unlink()
            stale.rmdir()
        return _Res(0)

    monkeypatch.setattr(m, "_run", fake_run)
    ok, detail = m._restart_vpnauthd()
    assert ok, detail
    assert "/usr/syno/bin" in seen["env"]["PATH"]
    assert "force-restart" in seen["cmd"]


def test_restart_fails_when_the_pid_does_not_change(monkeypatch, tmp_path):
    # The exact observed failure: rc 0, same pid, old site still being served.
    monkeypatch.setattr(m, "PROC_DIR", str(_fake_proc(tmp_path, [26836])))
    monkeypatch.setattr(m, "RESTART_TIMEOUT_S", 0.0)
    monkeypatch.setattr(m, "_run", lambda cmd, env=None: _Res(0))
    ok, detail = m._restart_vpnauthd()
    assert not ok
    assert "26836" in detail and "OLD RADIUS SITE" in detail


def test_restart_fails_when_the_daemon_does_not_come_back(monkeypatch, tmp_path):
    monkeypatch.setattr(m, "PROC_DIR", str(_fake_proc(tmp_path, [])))
    monkeypatch.setattr(m, "RESTART_TIMEOUT_S", 0.0)
    monkeypatch.setattr(m, "_run", lambda cmd, env=None: _Res(1, "boom"))
    ok, detail = m._restart_vpnauthd()
    assert not ok
    assert "did not come back up" in detail


def test_auth_reports_fail_when_the_restart_no_ops(monkeypatch, tmp_path, capsys):
    _stub_auth(monkeypatch, tmp_path)
    monkeypatch.setattr(m, "PROC_DIR", str(_fake_proc(tmp_path, [26836])))
    monkeypatch.setattr(m, "RESTART_TIMEOUT_S", 0.0)
    monkeypatch.setattr(m, "_run", lambda cmd, env=None: _Res(0))
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 1
    assert "FAIL" in capsys.readouterr().out


def _age_fake_daemon(seconds_ago=10_000):
    """Make the fake vpnauthd look as if it started before the config was
    written — the half-applied state the first real apply left behind."""
    for entry in os.listdir(m.PROC_DIR):
        if entry.isdigit():
            os.utime(os.path.join(m.PROC_DIR, entry), (1, 1))


def test_auth_reconverges_when_files_are_right_but_daemon_is_stale(
    monkeypatch, tmp_path, capsys
):
    """The half-applied state the first apply actually left behind: correct
    files, daemon still running the old site. File-drift alone sees nothing,
    so without the staleness check the role goes green on a broken box."""
    conf, _ = _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    capsys.readouterr()
    assert (conf / "rad_site_def").read_text().endswith("rad_site_def_ad\n")

    _age_fake_daemon()
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG", "--check"]) == 0
    out = capsys.readouterr().out
    assert "WOULD-CHANGE" in out and "vpnauthd" in out


def test_auth_is_no_change_when_daemon_is_newer_than_its_config(
    monkeypatch, tmp_path, capsys
):
    _stub_auth(monkeypatch, tmp_path)
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    capsys.readouterr()
    assert m.main(["auth", "--backend", "ad", "--domain", "KRG"]) == 0
    assert capsys.readouterr().out.startswith("OK no-change")


def test_published_ovpn_tells_users_to_qualify_the_username(monkeypatch, tmp_path):
    """Bare usernames are rejected by vpnauthd's Synology pre-check before
    ntlm_auth ever runs (measured 2026-08-25), so the self-serve config has to
    say so — it is the only instruction most users will ever read."""
    _stub_keys(monkeypatch, tmp_path)
    dest = tmp_path / "e4e-nas-vpn.ovpn"
    assert (
        m.main(
            [
                "publish",
                "--host", "e4e-nas.ucsd.edu",
                "--vpn-ip", "10.90.24.1",
                "--port", "1194",
                "--protocol", "udp",
                "--cipher", "AES-256-CBC",
                "--auth-digest", "SHA512",
                "--tls-auth", "true",
                "--dest", str(dest),
            ]
        )
        == 0
    )
    body = dest.read_text()
    assert "KRG\\<your-ad-username>" in body
    assert "REQUIRED" in body
