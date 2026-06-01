"""Unit tests for apply_ad.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_ad as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        if "method=test" in params:
            return live[api]["test"]
        if "method=start" in params:
            captured.append((api, params))
            return live[api].get("start", {"success": True})
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# --- domain-config -----------------------------------------------------------
_DESIRED_BASE = {
    # Simulate a joined state — do_domain_config short-circuits to
    # "OK no-change (deferred — not joined)" when current.enable_domain
    # is False (validated 2026-05-31 against live DSM: pre-join GET
    # returns only {enable_domain: false}, and SET silently drops the
    # other fields). Tests below exercise the joined path; the
    # unjoined short-circuit has its own test.
    "enable_domain": True,
    "realm": "KRG.LOCAL",
    "nbns_name": "krg.local",
    "server_address": "krg-ldap.krg.local",
    "server_ip": "137.110.161.109",
    "ou": "OU=NAS,OU=Hosts,DC=krg,DC=local",
    "idmap_type": "rid",
    "idmap_uid": "10000-2000000",
    "idmap_gid": "10000-2000000",
    "allowed_groups": ["Domain Admins"],
    "domain_admin_groups": ["Domain Admins"],
}


def _argv_domain_config(**overrides):
    base = {
        "realm": "KRG.LOCAL", "domain": "krg.local",
        "dc_host": "krg-ldap.krg.local", "dc_ip": "137.110.161.109",
        "ou": "OU=NAS,OU=Hosts,DC=krg,DC=local",
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
    fake, _ = _factory({m.DOMAIN_API: {"get": dict(_DESIRED_BASE)}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_domain_unjoined_short_circuits_to_no_change(monkeypatch, capsys):
    """When DSM reports `enable_domain: false` (NAS hasn't joined yet),
    do_domain_config short-circuits to OK no-change instead of trying
    to SET unjoinable fields. DSM silently drops realm/dc_host/idmap
    when not joined (validated 2026-05-31 on live e4e-nas), which made
    the role report false-positive CHANGED every run."""
    fake, captured = _factory({m.DOMAIN_API: {"get": {"enable_domain": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    out_err = capsys.readouterr()
    assert rc == 0
    assert "OK no-change" in out_err.out and "deferred" in out_err.out
    assert "not joined" in out_err.err
    # No SET attempted — only the GET happened
    assert not any("method=set" in p for a, p in captured)


def test_domain_idmap_drift(monkeypatch, capsys):
    live = dict(_DESIRED_BASE)
    live["idmap_type"] = "autorid"    # drift: live=autorid, spec=rid
    fake, captured = _factory({m.DOMAIN_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config())
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.DOMAIN_API and "method=set" in p)
    assert "idmap_type=rid" in set_call


def test_domain_check_mode_no_apply(monkeypatch, capsys):
    live = dict(_DESIRED_BASE)
    live["idmap_uid"] = "1000-1999"   # huge drift
    fake, captured = _factory({m.DOMAIN_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config() + ["--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.DOMAIN_API and "method=set" in p for a, p in captured)


def test_domain_allowed_groups_order_invariant(monkeypatch, capsys):
    live = dict(_DESIRED_BASE)
    live["allowed_groups"] = ["Domain Admins"]     # order-only
    fake, _ = _factory({m.DOMAIN_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_domain_config(allowed_groups=json.dumps(["Domain Admins"])))
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_domain_preserves_unmanaged_keys(monkeypatch, capsys):
    live = dict(_DESIRED_BASE)
    live["idmap_type"] = "autorid"
    live["winbind_advanced_thing"] = "preserve_me"
    fake, captured = _factory({m.DOMAIN_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(_argv_domain_config())
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.DOMAIN_API and "method=set" in p)
    assert "winbind_advanced_thing=preserve_me" in set_call


# --- test-join --------------------------------------------------------------
def test_test_join_joined(monkeypatch, capsys):
    fake, _ = _factory({m.JOIN_API: {"test": {"success": True,
                                              "data": {"joined": True, "realm": "KRG.LOCAL"}}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["test-join"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("JOINED KRG.LOCAL")


def test_test_join_not_joined(monkeypatch, capsys):
    fake, _ = _factory({m.JOIN_API: {"test": {"success": True,
                                              "data": {"joined": False}}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["test-join"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("NOT-JOINED")


def test_test_join_exec_failure_is_not_joined(monkeypatch, capsys):
    def raises(*_):
        raise RuntimeError("no API")
    monkeypatch.setattr(m, "_exec", raises)
    rc = m.main(["test-join"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("NOT-JOINED")


# --- join -------------------------------------------------------------------
def test_join_success(monkeypatch, capsys):
    fake, captured = _factory({m.JOIN_API: {"start": {"success": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "join", "--realm", "KRG.LOCAL", "--dc-host", "krg-ldap.krg.local",
        "--join-user", "Administrator", "--join-password", "secret",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    # password ends up on argv (necessary for the synowebapi call) — confirm it's there
    call = next(p for a, p in captured if a == m.JOIN_API)
    assert "password=secret" in call


def test_join_failure(monkeypatch, capsys):
    fake, _ = _factory({m.JOIN_API: {"start": {"success": False, "error": {"code": 5400}}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "join", "--realm", "KRG.LOCAL", "--dc-host", "krg-ldap.krg.local",
        "--join-user", "Administrator", "--join-password", "wrong",
    ])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")


def test_join_requires_password(monkeypatch, capsys):
    """Empty --join-password must FAIL fast (rc=1, 'FAIL' in stdout) without
    issuing a join call. We monkeypatch _exec to detect any unexpected call."""
    called = []
    monkeypatch.setattr(m, "_exec", lambda *a, **k: called.append(a) or {"success": True})
    rc = m.main([
        "join", "--realm", "KRG.LOCAL", "--dc-host", "krg-ldap.krg.local",
        "--join-user", "Administrator", "--join-password", "",
    ])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL")
    assert "join requires --join-password" in out
    assert called == [], "join must not call synowebapi when password is empty"
