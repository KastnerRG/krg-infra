"""Unit tests for apply_dsm_web.py — run with: pytest (no DSM needed).

Mocks the `_exec` subprocess boundary to drive the OK/WOULD-CHANGE/CHANGED/FAIL contract
and verifies the TLS profile name→integer mapping, the full-object overlay for Web.DSM,
and that `--check` doesn't mutate.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_dsm_web as m  # noqa: E402


def _live_web(hsts=False, avahi=True, ssdp=True, spdy=True, http_port=6020, https_port=6021):
    # Mirrors the real DSM v2 GET (capture 2026-05-28), with a couple of fields that
    # the role does NOT manage (max_connections_limit) to verify they're preserved.
    return {
        "enable_hsts": hsts, "enable_avahi": avahi, "enable_ssdp": ssdp,
        "enable_spdy": spdy, "enable_https": True, "enable_https_redirect": True,
        "enable_server_header": False, "http_port": http_port, "https_port": https_port,
        "main_app": "DSM", "fqdn": None,
        "max_connections_limit": {"lower": 4096, "upper": 262140},   # nested, untouched
    }


def _exec_factory(get_data, set_capture=None):
    """Build a fake _exec that returns canned GET data and records SET calls."""
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}
    return fake


def test_bool_helper():
    assert m._bool("true") and m._bool("YES") and m._bool("1")
    assert not (m._bool("false") or m._bool("0") or m._bool("off"))


def test_args_from_types():
    args = m._args_from({"a": True, "b": False, "n": None, "i": 3,
                         "nested": {"x": 1}})
    assert "a=true" in args and "b=false" in args and "i=3" in args
    assert not any(x.startswith("n=") for x in args)        # null dropped
    assert any(x.startswith("nested=") and '"x"' in x for x in args)


def test_tls_level_mapping():
    assert m.TLS_LEVELS == {"modern": 0, "intermediate": 1, "old": 2}


# --- web subcommand --------------------------------------------------------------
def test_web_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(_live_web(hsts=True, avahi=False, ssdp=False)))
    rc = m.main(["web", "--hsts", "true", "--avahi", "false", "--ssdp", "false"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_web_check_reports_drift_without_setting(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory(_live_web(hsts=False, avahi=True, ssdp=True)))
    rc = m.main(["web", "--hsts", "true", "--avahi", "false", "--ssdp", "false", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert "enable_hsts" in out and "enable_avahi" in out and "enable_ssdp" in out


def test_web_apply_sends_full_object_overlay(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        _live_web(hsts=False, avahi=True, ssdp=True), set_capture=captured))
    rc = m.main(["web", "--hsts", "true", "--avahi", "false", "--ssdp", "false"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    # exactly one set call, on Web.DSM v2
    assert len(captured) == 1
    api, params = captured[0]
    assert api == m.DSM_API
    assert "version=2" in params and "method=set" in params
    # managed fields overridden
    rest = set(params[2:])
    assert "enable_hsts=true" in rest and "enable_avahi=false" in rest and "enable_ssdp=false" in rest
    # unmanaged fields retained (full-object preserved)
    assert 'main_app="DSM"' in rest


def test_web_fail_on_unsuccessful_set(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": _live_web(hsts=False), "success": True}
        return {"success": False, "error": {"code": 2001}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["web", "--hsts", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- tls-profile subcommand ------------------------------------------------------
def test_tls_no_change_when_already_at_desired(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"default-level": 0}))
    rc = m.main(["tls-profile", "--profile", "modern"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_tls_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"default-level": 2}))
    rc = m.main(["tls-profile", "--profile", "modern", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and '"current": 2' in out and '"desired": 0' in out


def test_tls_apply_sends_correct_level(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory({"default-level": 2}, set_capture=captured))
    rc = m.main(["tls-profile", "--profile", "modern"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    api, params = captured[0]
    assert api == m.TLS_API and "default-level=0" in params


def test_tls_raw_level_override(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory({"default-level": 0}, set_capture=captured))
    # explicit --level overrides --profile; 5 is bogus, but the helper passes it through
    rc = m.main(["tls-profile", "--profile", "modern", "--level", "5"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    assert "default-level=5" in captured[0][1]


def test_tls_unknown_profile_errors(monkeypatch):
    monkeypatch.setattr(m, "_exec", _exec_factory({"default-level": 0}))
    try:
        m.main(["tls-profile", "--profile", "bogus"])
        raise AssertionError("expected SystemExit")
    except SystemExit:
        pass
