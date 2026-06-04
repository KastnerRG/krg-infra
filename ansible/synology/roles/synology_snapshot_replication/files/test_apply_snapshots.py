"""Unit tests for apply_snapshots.py — run with: pytest (no DSM needed)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_snapshots as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


_DEFAULTS = {
    "enable_snapshot": True,
    "keep_hourly": 4, "keep_daily": 7, "keep_weekly": 4, "keep_monthly": 12,
}


def _argv_share(**overrides):
    base = {"share": "maya", "enabled": "true",
            "hourly": "4", "daily": "7", "weekly": "4", "monthly": "12"}
    base.update(overrides)
    argv = ["share"]
    for k, v in base.items():
        argv += ["--" + k, str(v)]
    return argv


def test_share_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.SNAP_API: {"get": dict(_DEFAULTS)}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_share())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_share_drift_apply(monkeypatch, capsys):
    live = dict(_DEFAULTS)
    live["keep_daily"] = 1   # drift
    fake, captured = _factory({m.SNAP_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_share())
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.SNAP_API)
    assert "keep_daily=7" in set_call
    assert "name=maya" in set_call


def test_share_disable(monkeypatch, capsys):
    live = dict(_DEFAULTS)
    fake, captured = _factory({m.SNAP_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_share(enabled="false"))
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.SNAP_API)
    assert "enable_snapshot=false" in set_call


def test_share_check_mode(monkeypatch, capsys):
    live = dict(_DEFAULTS)
    live["keep_monthly"] = 1
    fake, captured = _factory({m.SNAP_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(_argv_share() + ["--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.SNAP_API and "method=set" in p for a, p in captured)


def test_share_preserves_unmanaged_keys(monkeypatch, capsys):
    live = dict(_DEFAULTS)
    live["keep_daily"] = 1
    live["dsm_share_id"] = 42     # unmanaged
    fake, captured = _factory({m.SNAP_API: {"get": live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(_argv_share())
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.SNAP_API)
    assert "dsm_share_id=42" in set_call
