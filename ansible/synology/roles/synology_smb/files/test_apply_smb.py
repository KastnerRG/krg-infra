"""Unit tests for apply_smb.py — run with: pytest (no DSM needed).

The subprocess boundary is `get_settings`/`set_settings` (which call synowebapi); we
monkeypatch those to drive the OK/WOULD-CHANGE/CHANGED/FAIL contract the role keys off,
and test the pure arg/type helpers directly.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_smb as m  # noqa: E402


def _boom(*a, **k):
    raise AssertionError("must not be called")


def _ns(**kw):
    base = dict(min_protocol=None, max_protocol=None, enable=None,
                server_signing=None, ntlmv1_auth=None, check=False)
    base.update(kw)
    return argparse.Namespace(**base)


def _live(signing=0, minp=1, maxp=3):
    # mirrors a real version-3 GET (subset), incl. a null field set() must drop
    return {"enable_samba": True, "enable_server_signing": signing,
            "smb_min_protocol": minp, "smb_max_protocol": maxp,
            "enable_adserver": None, "workgroup": "WORKGROUP"}


def test_bool():
    assert m._bool("true") and m._bool("ON") and m._bool("1") and m._bool("yes")
    assert not (m._bool("false") or m._bool("0") or m._bool("off"))


def test_desired_from_args_maps_names_and_types():
    d = m.desired_from_args(_ns(min_protocol="SMB3", max_protocol="SMB3",
                                 enable="true", server_signing="true", ntlmv1_auth="false"))
    assert d == {"smb_min_protocol": 3, "smb_max_protocol": 3, "enable_samba": True,
                 "enable_server_signing": 1, "enable_ntlmv1_auth": False}


def test_desired_from_args_partial_only_given():
    assert m.desired_from_args(_ns(min_protocol="SMB2")) == {"smb_min_protocol": 2}


def test_set_settings_arg_building(monkeypatch):
    seen = {}

    def fake_exec(*params):
        seen["p"] = params
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake_exec)
    m.set_settings({"a": True, "b": False, "n": None, "i": 3, "s": "x"})
    p = seen["p"]
    assert p[0] == "version=3" and p[1] == "method=set"
    rest = set(p[2:])
    assert {"a=true", "b=false", "i=3", "s=x"} <= rest
    assert not any(x.startswith("n=") for x in rest)  # null dropped


def test_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "get_settings", lambda: _live(signing=1, minp=3, maxp=3))
    monkeypatch.setattr(m, "set_settings", _boom)
    rc = m.main(["--min-protocol", "SMB3", "--max-protocol", "SMB3", "--server-signing", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_check_reports_drift_without_setting(monkeypatch, capsys):
    monkeypatch.setattr(m, "get_settings", lambda: _live(signing=0, minp=1))
    monkeypatch.setattr(m, "set_settings", _boom)
    rc = m.main(["--min-protocol", "SMB3", "--server-signing", "true", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert "smb_min_protocol" in out and "enable_server_signing" in out


def test_apply_sets_full_object(monkeypatch, capsys):
    captured = {}

    def fake_set(data):
        captured["data"] = data
        return {"success": True}

    monkeypatch.setattr(m, "get_settings", lambda: _live(signing=0, minp=1))
    monkeypatch.setattr(m, "set_settings", fake_set)
    rc = m.main(["--min-protocol", "SMB3", "--server-signing", "true"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert captured["data"]["smb_min_protocol"] == 3
    assert captured["data"]["enable_server_signing"] == 1
    assert captured["data"]["workgroup"] == "WORKGROUP"  # untouched field retained


def test_fail_when_set_unsuccessful(monkeypatch, capsys):
    monkeypatch.setattr(m, "get_settings", lambda: _live(signing=0))
    monkeypatch.setattr(m, "set_settings", lambda d: {"success": False, "error": {"code": 2001}})
    rc = m.main(["--server-signing", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")
