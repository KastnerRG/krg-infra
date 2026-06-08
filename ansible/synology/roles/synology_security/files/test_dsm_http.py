"""Unit tests for the inlined DSMSession in apply_security.py — mock urllib at the opener level."""

import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_security as m  # noqa: E402  (DSMSession + DSMError live here now)


class _FakeResp(io.BytesIO):
    """urllib opener-compatible response (.read(), context manager)."""

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _opener_factory(responses):
    """responses: list of dicts to JSON-encode + return in order.
    The fake opener captures (url, data, headers) per call into `.calls`.
    """
    state = {"calls": [], "responses": list(responses)}

    class FakeOpener:
        def open(self, req, timeout=None):
            state["calls"].append(
                {
                    "url": req.full_url,
                    "data": req.data,
                    "headers": dict(req.headers),
                }
            )
            return _FakeResp(json.dumps(state["responses"].pop(0)).encode())

    return FakeOpener(), state


def _new_session(monkeypatch, responses):
    opener, state = _opener_factory(responses)
    s = m.DSMSession(password="pw")
    monkeypatch.setattr(s, "_opener", opener)
    return s, state


def test_call_json_encodes_strings_with_quotes(monkeypatch):
    """call() must JSON-quote string params (the DSM webapi convention)."""
    s, state = _new_session(monkeypatch, [{"success": True, "data": {"ok": 1}}])
    s.token = "TOK"
    s.call("Some.Api", "get", version=1, name="default", count=3, flag=True)
    body = state["calls"][0]["data"].decode()
    # name=%22default%22 → name=\"default\" (JSON-quoted)
    assert "name=%22default%22" in body
    assert "count=3" in body  # ints stay int
    assert "flag=true" in body  # bools lowercase
    assert "api=Some.Api" in body
    assert "method=get" in body
    assert "version=1" in body


def test_call_sends_token_header_when_present(monkeypatch):
    s, state = _new_session(monkeypatch, [{"success": True, "data": {}}])
    s.token = "ABC123"
    s.call("X", "y", version=1)
    # urllib normalises header keys: X-Syno-Token
    headers = state["calls"][0]["headers"]
    assert headers.get("X-syno-token") == "ABC123" or headers.get("X-Syno-Token") == "ABC123"


def test_call_omits_token_header_before_login(monkeypatch):
    s, state = _new_session(monkeypatch, [{"success": True, "data": {}}])
    s.token = None
    s.call("X", "y", version=1)
    headers = state["calls"][0]["headers"]
    assert not any(k.lower() == "x-syno-token" for k in headers)


def test_login_captures_token(monkeypatch):
    s, state = _new_session(
        monkeypatch,
        [
            {"success": True, "data": {"synotoken": "T0KEN", "sid": "S"}},
        ],
    )
    data = s.login()
    assert s.token == "T0KEN"
    assert data["sid"] == "S"
    body = state["calls"][0]["data"].decode()
    assert "account=e4e-admin" in body
    assert "enable_syno_token=yes" in body
    assert "format=cookie" in body


def test_login_failure_raises(monkeypatch):
    s, _ = _new_session(
        monkeypatch,
        [
            {"success": False, "error": {"code": 400}},
        ],
    )
    import pytest

    with pytest.raises(m.DSMError) as exc:
        s.login()
    assert exc.value.code == 400
    assert s.token is None


def test_profile_set_sends_full_profile_json(monkeypatch):
    """profile_set must send the profile as one JSON-encoded form field
    (matches what the DSM UI sends; we captured the shape in a HAR)."""
    s, state = _new_session(monkeypatch, [{"success": True, "data": {}}])
    s.token = "T"
    profile = {
        "name": "default",
        "global": {"policy": "deny", "rules": [{"name": "r1", "policy": "allow"}]},
    }
    s.profile_set(profile, applying=False)
    body = state["calls"][0]["data"].decode()
    assert "api=SYNO.Core.Security.Firewall.Profile" in body
    assert "method=set" in body
    assert "profile_applying=false" in body
    # The profile= field is JSON-encoded then URL-encoded; decode + parse it
    import urllib.parse as up

    qs = up.parse_qs(body)
    assert json.loads(qs["profile"][0]) == profile


def test_profile_apply_two_phase_polls_until_finish(monkeypatch):
    """profile_apply: start → status polls until finish=true → stop."""
    s, state = _new_session(
        monkeypatch,
        [
            {"success": True, "data": {"task_id": "@adm/fw123"}},
            {"success": True, "data": {"finish": False}},
            {"success": True, "data": {"finish": True}},
            {"success": True, "data": {}},  # stop
        ],
    )
    s.token = "T"
    # No sleeping during tests — patch out time.sleep
    import time as _time

    monkeypatch.setattr(_time, "sleep", lambda *a, **k: None)
    result = s.profile_apply("default", poll_interval=0.001, timeout=5)
    assert result["finish"] is True
    # 4 calls: start, status, status, stop
    assert len(state["calls"]) == 4
    bodies = [c["data"].decode() for c in state["calls"]]
    assert "method=start" in bodies[0]
    assert "profile_applying=false" in bodies[0]  # matches UI value
    assert "method=status" in bodies[1] and "task_id=" in bodies[1]
    assert "method=status" in bodies[2]
    assert "method=stop" in bodies[3]


def test_profile_apply_stop_called_even_on_timeout(monkeypatch):
    """If status never reports finish, stop must still run (finally block)."""
    s, state = _new_session(
        monkeypatch,
        [
            {"success": True, "data": {"task_id": "@adm/fw123"}},
            {"success": True, "data": {"finish": False}},  # never finishes
            {"success": True, "data": {}},  # stop in finally
        ],
    )
    s.token = "T"
    import time as _time

    monkeypatch.setattr(_time, "sleep", lambda *a, **k: None)
    # Force timeout immediately: set monotonic to advance
    times = iter([0.0, 100.0, 200.0])
    monkeypatch.setattr(_time, "monotonic", lambda: next(times))
    import pytest

    with pytest.raises(m.DSMError) as exc:
        s.profile_apply("default", poll_interval=0.001, timeout=1)
    assert "timed out" in str(exc.value)
    # stop was called as the final request
    assert "method=stop" in state["calls"][-1]["data"].decode()


def test_context_manager_logs_out_on_exit(monkeypatch):
    """`with DSMSession() as s:` must call logout on __exit__ even after exceptions."""
    opener, state = _opener_factory(
        [
            {"success": True, "data": {"synotoken": "T"}},  # login
            {"success": True, "data": {}},  # logout
        ]
    )
    s = m.DSMSession(password="pw")
    monkeypatch.setattr(s, "_opener", opener)
    with s:
        pass
    bodies = [c["data"].decode() for c in state["calls"]]
    assert "method=login" in bodies[0]
    assert "method=logout" in bodies[1]
    assert s.token is None


def test_context_manager_swallows_logout_errors(monkeypatch):
    """Logout failure during __exit__ must not mask the original exception."""
    opener, state = _opener_factory(
        [
            {"success": True, "data": {"synotoken": "T"}},
            {"success": False, "error": {"code": 119}},  # logout fails
        ]
    )
    s = m.DSMSession(password="pw")
    monkeypatch.setattr(s, "_opener", opener)
    import pytest

    with pytest.raises(ValueError) as exc:
        with s:
            raise ValueError("inner")
    assert str(exc.value) == "inner"
