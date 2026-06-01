"""Unit tests for apply_dsm_updates.py — run with: pytest (no DSM needed).

Field shape EMPIRICALLY CONFIRMED 2026-05-29 from a live
`Upgrade.Setting v2 get` on the e4e-nas. Earlier `auto_update_type`/
`enable_auto_update`/`upgrade_day` test fixtures were based on the original
best-known guess (which DSM didn't accept) — replaced by these.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_dsm_updates as m  # noqa: E402


def _factory(live):
    """live: dict of API → {get: {...}}. set/etc calls are captured for assertions.
    `live[api]["get"]` is what the fake GET returns; v2 nests `schedule`."""
    captured = []

    def fake(api, version, method, *params):
        if method == "get":
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, version, method, params))
        return {"success": True}

    return fake, captured


# Canonical "already converged" live state (DSM 7.3 Upgrade.Setting v2 shape).
_CONVERGED = {
    "autoupdate_enable": True,
    "autoupdate_type":   "hotfix-security",
    "schedule": {"hour": 3, "minute": 0, "week_day": "0"},  # Sun=0
    "smart_nano_enabled": True,        # DSM-internal, unmanaged
    "upgrade_type":       "hotfix",    # legacy duplicate, unmanaged
}


# --- setting -------------------------------------------------------------------
def test_setting_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.UPD_SETTING_API: {"get": dict(_CONVERGED,
                                                        schedule=dict(_CONVERGED["schedule"]))}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_setting_drift_applies_real_field_names(monkeypatch, capsys):
    """SET must use `autoupdate_enable`/`autoupdate_type` (the REAL DSM fields),
    not the original best-known guesses `enable_auto_update`/`auto_update_type`."""
    drift_live = {
        "autoupdate_enable": False,
        "autoupdate_type":   "nothing",
        "schedule": {"hour": 5, "minute": 0, "week_day": "1"},
        "smart_nano_enabled": True,
    }
    fake, captured = _factory({m.UPD_SETTING_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    set_call = next(p for a, v, mth, p in captured
                    if a == m.UPD_SETTING_API and mth == "set")
    assert "autoupdate_enable=true" in set_call
    assert 'autoupdate_type="hotfix-security"' in set_call


def test_setting_uses_v2_not_v1(monkeypatch, capsys):
    """Must call version=2 (richest shape). v1 only returns 2 fields and
    silently drops most of what we want to manage."""
    fake, captured = _factory({m.UPD_SETTING_API: {"get": dict(_CONVERGED,
                                                              schedule=dict(_CONVERGED["schedule"],
                                                                            week_day="1"))}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
            "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0"])
    capsys.readouterr()
    set_calls = [v for a, v, mth, _ in captured if mth == "set"]
    assert set_calls, "expected a SET call"
    assert all(v == 2 for v in set_calls), "SET must use version=2: " + str(set_calls)


def test_setting_merges_nested_schedule(monkeypatch, capsys):
    """`schedule` is NESTED under DSM v2 — SET must send a single nested
    schedule dict, not flat `week_day=..`/`schedule.week_day=..` keys."""
    drift_live = dict(_CONVERGED, schedule={"hour": 5, "minute": 0, "week_day": "1"})
    fake, captured = _factory({m.UPD_SETTING_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
            "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0"])
    capsys.readouterr()
    set_call = next(p for a, v, mth, p in captured
                    if a == m.UPD_SETTING_API and mth == "set")
    # Find the schedule= token, parse its JSON value, assert nesting.
    schedule_token = next(t for t in set_call if t.startswith("schedule="))
    import json as _json
    sched = _json.loads(schedule_token[len("schedule="):])
    assert sched.get("week_day") == "0"   # Sun -> "0"
    assert sched.get("hour") == 3
    assert sched.get("minute") == 0
    # NO flat counterparts at top level
    assert not any(t.startswith("week_day=") for t in set_call), \
        "week_day must NOT appear at top level — it's nested under schedule"


def test_setting_day_validation_rejects_garbage():
    try:
        m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
                "--notify-email", "true", "--day", "Funday",
                "--hour", "3", "--minute", "0"])
    except SystemExit as e:
        assert "Funday" in str(e) or "--day" in str(e)
    else:
        assert False, "should have raised SystemExit on bad --day"


def test_setting_preserves_unmanaged_keys(monkeypatch, capsys):
    """Full-object SET must round-trip `smart_nano_enabled` / `upgrade_type` and
    any other unmanaged DSM-internal keys, else DSM may reset them or err 2001."""
    drift_live = dict(_CONVERGED,
                      autoupdate_enable=False,
                      smart_nano_enabled=True,
                      upgrade_type="hotfix",
                      unknown_dsm_internal_key="preserve_me",
                      schedule=dict(_CONVERGED["schedule"]))
    fake, captured = _factory({m.UPD_SETTING_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
            "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0"])
    capsys.readouterr()
    set_call = next(p for a, v, mth, p in captured
                    if a == m.UPD_SETTING_API and mth == "set")
    assert "smart_nano_enabled=true" in set_call
    assert 'upgrade_type="hotfix"' in set_call
    assert 'unknown_dsm_internal_key="preserve_me"' in set_call


def test_setting_check_mode_no_apply(monkeypatch, capsys):
    drift_live = dict(_CONVERGED, autoupdate_enable=False,
                      schedule=dict(_CONVERGED["schedule"]))
    fake, captured = _factory({m.UPD_SETTING_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
                 "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
                 "--check"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(mth == "set" for a, v, mth, _ in captured)


def test_setting_notify_email_is_accepted_but_no_op(monkeypatch, capsys):
    """`--notify-email` exists for spec stability but DOES NOT appear on the
    wire — notify email is owned by SYNO.Core.Notification.Event, not by
    Upgrade.Setting (the field doesn't exist in v2 get/set)."""
    fake, captured = _factory({m.UPD_SETTING_API: {"get": dict(_CONVERGED,
                                                              schedule=dict(_CONVERGED["schedule"],
                                                                            week_day="1"))}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
            "--notify-email", "false",  # spec says off
            "--day", "Sun", "--hour", "3", "--minute", "0"])
    capsys.readouterr()
    set_call = next(p for a, v, mth, p in captured
                    if a == m.UPD_SETTING_API and mth == "set")
    # No notify_email field should be set on the wire (Notification.Event owns it)
    assert not any(t.startswith("notify_email=") for t in set_call), \
        "notify_email must NOT be sent — it's not an Upgrade.Setting field"


def test_setting_update_channel_is_accepted_but_no_op(monkeypatch, capsys):
    """`--update-channel` exists for spec stability but DSM `Upgrade.Server`
    has no `set` method — channel selection is immutable from WebAPI on
    DSM 7.3 SOHO. Spec value MUST NOT appear on the Setting SET payload either."""
    fake, captured = _factory({m.UPD_SETTING_API: {"get": dict(_CONVERGED,
                                                              schedule=dict(_CONVERGED["schedule"],
                                                                            week_day="1"))}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
            "--notify-email", "true", "--update-channel", "beta",
            "--day", "Sun", "--hour", "3", "--minute", "0"])
    capsys.readouterr()
    set_call = next(p for a, v, mth, p in captured
                    if a == m.UPD_SETTING_API and mth == "set")
    # No `type=beta` token (would leak to UPD_SETTING_API which doesn't have it)
    assert not any(t.startswith("type=") for t in set_call), \
        "channel must NOT leak into Setting payload — it has no set method on Server"
    # Also confirm we never tried to call Upgrade.Server set
    assert not any("Upgrade.Server" in a for a, v, mth, _ in captured), \
        "must NOT call Upgrade.Server — no set method exists on this DSM"


# --- err 102 / err 103 — fail loudly --------------------------------------------
def test_err102_get_fails_loudly(monkeypatch, capsys):
    def fake(api, version, method, *params):
        return {"success": False, "error": {"code": 102}}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["setting", "--policy", "hotfix-security", "--auto-install", "true",
                 "--notify-email", "true", "--day", "Sun",
                 "--hour", "3", "--minute", "0"])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL")
    assert "102" in out


# --- M5 regression: type-coerced diff comparison ---------------------------------
def test_setting_string_int_returned_by_dsm_is_not_drift(monkeypatch, capsys):
    """DSM v2 returns nested `schedule.hour` as int; defensive check that a
    string-typed legacy variant doesn't false-positive drift either."""
    str_live = dict(_CONVERGED,
                    autoupdate_enable="true",  # string instead of bool
                    schedule={"hour": "3", "minute": "0", "week_day": "0"})
    fake, _ = _factory({m.UPD_SETTING_API: {"get": str_live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "setting", "--policy", "hotfix-security", "--auto-install", "true",
        "--notify-email", "true", "--day", "Sun", "--hour", "3", "--minute", "0",
    ])
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
