"""Unit tests for apply_app_portal.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_app_portal as m  # noqa: E402


def _factory(live):
    """live: dict of API → either {data:...} GET-shaped or list for `list` calls.
    Set/create/update/delete calls are captured for assertions.
    """
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        if "method=list" in params:
            return {"data": dict(live[api]["list"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# --- config (full-object set) ----------------------------------------------------
def test_config_no_change(monkeypatch, capsys):
    fake, _ = _factory({"SYNO.Core.AppPortal.Config": {"get": {"show_titlebar": True}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["config", "--show-titlebar", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_config_apply_drift(monkeypatch, capsys):
    fake, captured = _factory({"SYNO.Core.AppPortal.Config": {"get": {"show_titlebar": False}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["config", "--show-titlebar", "true"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    assert "show_titlebar=true" in captured[0][1]


# --- declarative list sync -------------------------------------------------------
def test_reverse_proxy_empty_lists(monkeypatch, capsys):
    fake, _ = _factory({"SYNO.Core.AppPortal.ReverseProxy": {"list": {"entries": []}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["reverse-proxy", "--entries", "[]"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_reverse_proxy_create_update_delete(monkeypatch, capsys):
    live = [
        {"id": 1, "alias": "keep_unchanged", "fqdn": "k.example", "https": True},
        {"id": 2, "alias": "to_be_updated",  "fqdn": "u.example", "https": False},
        {"id": 3, "alias": "to_be_deleted",  "fqdn": "d.example", "https": False},
    ]
    desired = [
        {"id": 1, "alias": "keep_unchanged", "fqdn": "k.example", "https": True},
        {"id": 2, "alias": "to_be_updated",  "fqdn": "u.example", "https": True},   # changed https
        {"alias": "newly_added",             "fqdn": "n.example", "https": True},   # no id → create
    ]
    fake, captured = _factory({"SYNO.Core.AppPortal.ReverseProxy": {"list": {"entries": live}}})
    monkeypatch.setattr(m, "_exec", fake)

    rc = m.main(["reverse-proxy", "--entries", json.dumps(desired)])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")

    methods = {tok for _, p in captured for tok in p if tok.startswith("method=")}
    # one of each
    assert "method=create" in methods
    assert "method=update" in methods
    assert "method=delete" in methods


def test_reverse_proxy_check_only(monkeypatch, capsys):
    live = [{"id": 1, "fqdn": "old", "alias": "a"}]
    desired = [{"id": 1, "fqdn": "new", "alias": "a"}]
    fake, captured = _factory({"SYNO.Core.AppPortal.ReverseProxy": {"list": {"entries": live}}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["reverse-proxy", "--entries", json.dumps(desired), "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    # nothing should have been mutated (no create/update/delete captured)
    method_calls = [p for _, p in captured if any(x.startswith("method=") and x != "method=list" for x in p)]
    assert method_calls == []


def test_access_control_uses_same_diff(monkeypatch, capsys):
    fake, captured = _factory({"SYNO.Core.AppPortal.AccessControl": {"list": {"entries": []}}})
    monkeypatch.setattr(m, "_exec", fake)
    desired = [{"alias": "rule1", "deny": "*"}]
    rc = m.main(["access-control", "--entries", json.dumps(desired)])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    apis = {a for a, _ in captured}
    assert apis == {"SYNO.Core.AppPortal.AccessControl"}


# --- H1: failure surfaces, doesn't get swallowed as success ----------------------
def test_reverse_proxy_create_failure_reports_FAIL(monkeypatch, capsys):
    """A `success: false` from DSM on create must propagate as FAIL, not CHANGED."""
    live = []
    desired = [{"alias": "new_one", "fqdn": "n.example", "https": True}]

    call_counter = {"n": 0}

    def fake(api, *params):
        if "method=list" in params:
            return {"data": {"entries": list(live)}, "success": True}
        # First create returns DSM err 2001 (partial-set / bad payload)
        call_counter["n"] += 1
        return {"success": False, "error": {"code": 2001}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["reverse-proxy", "--entries", json.dumps(desired)])
    out = capsys.readouterr().out
    assert rc == 1
    assert out.startswith("FAIL")
    # Confirm we actually attempted the create (regression guard against
    # short-circuiting before the apply runs).
    assert call_counter["n"] >= 1


def test_reverse_proxy_update_failure_reports_FAIL(monkeypatch, capsys):
    live = [{"id": 5, "alias": "x", "fqdn": "a", "https": False}]
    desired = [{"id": 5, "alias": "x", "fqdn": "a", "https": True}]   # update

    def fake(api, *params):
        if "method=list" in params:
            return {"data": {"entries": list(live)}, "success": True}
        if "method=update" in params:
            return {"success": False, "error": {"code": 400}}
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["reverse-proxy", "--entries", json.dumps(desired)])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")


# --- Low: delete-key fallback (alias / name when id missing) ----------------------
def test_delete_falls_back_to_alias_when_no_id(monkeypatch, capsys):
    """An entry the role knows only by alias (no id from DSM) must still delete cleanly."""
    live = [{"alias": "no_id_entry", "fqdn": "x.example", "https": False}]   # no id field

    captured = []

    def fake(api, *params):
        if "method=list" in params:
            return {"data": {"entries": list(live)}, "success": True}
        captured.append((api, params))
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["reverse-proxy", "--entries", "[]"])   # desired empty → delete live
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    # The delete call MUST carry alias=, not an empty id= (the prior bug).
    del_call = next(p for _, p in captured if "method=delete" in p)
    assert 'alias="no_id_entry"' in del_call
    assert not any(tok.startswith("id=") and tok.endswith("=") for tok in del_call)
