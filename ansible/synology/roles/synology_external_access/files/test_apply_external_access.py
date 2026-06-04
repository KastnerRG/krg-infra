"""Unit tests for apply_external_access.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_external_access as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_quickconnect_disable_drift(monkeypatch, capsys):
    fake, captured = _factory({m.QC_API: {"get": {"enabled": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["quickconnect", "--enable", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.QC_API)
    assert "enabled=false" in set_call


def test_quickconnect_already_off(monkeypatch, capsys):
    fake, _ = _factory({m.QC_API: {"get": {"enabled": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["quickconnect", "--enable", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_upnp_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.UPNP_API: {"get": {"enabled": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "false", "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.UPNP_API and "method=set" in p for a, p in captured)


def test_ddns_drift_and_full_object_preservation(monkeypatch, capsys):
    fake, captured = _factory({m.DDNS_API: {"get": {
        "enabled": True,
        "provider": "Synology",     # unmanaged — must round-trip
        "hostname": "e4e-nas.synology.me",
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["ddns", "--enable", "false"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.DDNS_API)
    assert "enabled=false" in set_call
    # Unmanaged keys preserved (DSM full-object set requires them)
    assert 'provider="Synology"' in set_call
    assert 'hostname="e4e-nas.synology.me"' in set_call


def test_each_surface_targets_correct_api(monkeypatch, capsys):
    live = {
        m.QC_API:   {"get": {"enabled": True}},
        m.UPNP_API: {"get": {"enabled": True}},
        m.DDNS_API: {"get": {"enabled": True}},
    }
    fake, captured = _factory(live)
    monkeypatch.setattr(m, "_exec", fake)
    for sub in ("quickconnect", "upnp", "ddns"):
        m.main([sub, "--enable", "false"])
    capsys.readouterr()
    apis = {a for a, _ in captured}
    assert apis == {m.QC_API, m.UPNP_API, m.DDNS_API}


# --- err 102 (API does not exist) absence handling --------------------------
def _err102_factory():
    """Fake _exec that returns err 102 on GET (API absent) for any api,
    and would record any SET attempt (there should be none on a clean skip)."""
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"success": False, "error": {"code": 102}}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


def test_err102_absent_api_with_disabled_desired_is_noop(monkeypatch, capsys):
    """Regression for e4e-nas first-apply: SOHO units lack the Router.UPnP
    API entirely (err 102). When spec wants UPnP disabled, absence IS the
    desired state — must report `OK no-change` and NOT call SET."""
    fake, captured = _err102_factory()
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "false"])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
    # CRITICAL: no SET call attempted on an absent API (would error 102 again)
    assert not any("method=set" in p for _, p in captured)


def test_err102_absent_api_with_enabled_desired_fails_loudly(monkeypatch, capsys):
    """If the operator changes spec to `enable: true` but the API is absent,
    we can't satisfy that — fail loudly so they notice instead of silently
    skipping. Should also work for QC/DDNS by the same path."""
    fake, _ = _err102_factory()
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "true"])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL")
    assert "102" in out
    assert "not present" in out  # the operator-friendly note


def test_other_get_failure_is_loud(monkeypatch, capsys):
    """A non-102 GET error (perm denied, unknown method, etc.) must FAIL even
    when desired=disabled — we can't assume absence == desired for arbitrary
    errors. Only err 102 has that semantics."""
    def fake(api, *params):
        if "method=get" in params:
            return {"success": False, "error": {"code": 401}}  # perm denied-ish
        return {"success": True}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "false"])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL")
    assert "401" in out


def test_success_but_no_data_key_fails_loudly(monkeypatch, capsys):
    """Protocol violation: success=true with no data dict. Must FAIL clearly
    instead of KeyError'ing on `resp['data']` (the original bug we fixed)."""
    def fake(api, *params):
        if "method=get" in params:
            return {"success": True}  # NO `data` key
        return {"success": True}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["upnp", "--enable", "false"])
    assert rc == 1
    assert "no `data` key" in capsys.readouterr().out
