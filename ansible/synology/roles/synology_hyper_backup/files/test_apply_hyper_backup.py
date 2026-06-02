"""Unit tests for apply_hyper_backup.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_hyper_backup as m  # noqa: E402


def _factory(live_tasks, set_results=None):
    """live_tasks: list of dicts (each with at least task_name + id).
    set_results: optional override per call (default success=True).
    """
    captured = []
    set_results = set_results or {}

    def fake(api, *params):
        if "method=list" in params:
            return {"success": True, "data": {"tasks": list(live_tasks)}}
        captured.append((api, params))
        method = next((p for p in params if p.startswith("method=")), "")
        method = method.replace("method=", "")
        return set_results.get(method, {"success": True})

    return fake, captured


_SECRETS = json.dumps({"critical-shares-offbox": "s3cret"})
_DEFAULTS = json.dumps({"encrypt": True, "enabled": True})


def _job(name="critical-shares-offbox", **over):
    base = {
        "name": name,
        "destination": {"type": "rsync", "host": "krg-prod.ucsd.edu",
                        "path": "/var/backup/e4e-nas/hyperbackup"},
        "sources": ["admin", "programmatics"],
        "schedule": {"daily": "03:00", "retain_versions": 30},
        "encrypt": True,
        "enabled": True,
    }
    base.update(over)
    return base


def _live(name="critical-shares-offbox", id_=7, **over):
    base = {
        m.OUT_KEYS["name"]: name,
        "id": id_,
        m.OUT_KEYS["dest_type"]: "rsync",
        m.OUT_KEYS["dest_host"]: "krg-prod.ucsd.edu",
        m.OUT_KEYS["dest_path"]: "/var/backup/e4e-nas/hyperbackup",
        m.OUT_KEYS["sources"]: ["admin", "programmatics"],
        m.OUT_KEYS["schedule_daily"]: "03:00",
        m.OUT_KEYS["retain"]: 30,
        m.OUT_KEYS["encrypt"]: True,
        m.OUT_KEYS["enabled"]: True,
    }
    base.update(over)
    return base


def test_no_change(monkeypatch, capsys):
    fake, _ = _factory([_live()])
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs", "--desired", json.dumps([_job()]),
                 "--defaults", _DEFAULTS, "--secrets", _SECRETS])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_empty_lists(monkeypatch, capsys):
    fake, _ = _factory([])
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs", "--desired", "[]", "--defaults", _DEFAULTS, "--secrets", "{}"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_create_update_delete(monkeypatch, capsys):
    live = [
        _live(name="critical-shares-offbox", id_=1),
        _live(name="old-task", id_=2),                  # to be deleted
    ]
    desired = [
        _job(name="critical-shares-offbox",
             sources=["admin", "programmatics", "label_studio"]),  # update (sources changed)
        _job(name="brand-new"),                          # create
    ]
    secrets = json.dumps({"critical-shares-offbox": "x", "brand-new": "y"})
    fake, captured = _factory(live)
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs", "--desired", json.dumps(desired),
                 "--defaults", _DEFAULTS, "--secrets", secrets])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    methods = {p.replace("method=", "") for _, params in captured for p in params if p.startswith("method=")}
    assert "create" in methods
    assert "update" in methods
    assert "delete" in methods


def test_check_mode_no_apply(monkeypatch, capsys):
    live = [_live()]
    desired = [_job(sources=["admin", "programmatics", "label_studio"])]
    fake, captured = _factory(live)
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs", "--desired", json.dumps(desired),
                 "--defaults", _DEFAULTS, "--secrets", _SECRETS, "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    # No mutating calls captured (list method goes through the get-path)
    assert not any("method=create" in p or "method=update" in p or "method=delete" in p
                   for _, params in captured for p in params)


def test_encrypted_without_secret_is_skipped(monkeypatch, capsys):
    """Encrypted job with no secret entry must NOT be created (assert in role
    already warns; helper itself defensively skips so apply is safe)."""
    fake, captured = _factory([])
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs",
                 "--desired", json.dumps([_job(encrypt=True)]),
                 "--defaults", _DEFAULTS,
                 "--secrets", "{}"])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out


def test_sources_order_invariant(monkeypatch, capsys):
    live = [_live(sources=["programmatics", "admin"])]
    desired = [_job(sources=["admin", "programmatics"])]
    fake, _ = _factory(live)
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["jobs", "--desired", json.dumps(desired),
                 "--defaults", _DEFAULTS, "--secrets", _SECRETS])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
