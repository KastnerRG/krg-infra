"""Unit tests for apply_security_advisor.py — run with: pytest (no DSM needed).

Field shape EMPIRICALLY CONFIRMED 2026-05-29 from
`/usr/syno/synoman/webapi/SYNO.Core.SecurityScan.lib` on the live e4e-nas + a
live `Conf.get` capture. Earlier `.Main`/`enable`/`schedule_day` test fixtures
were based on the original best-known guess — replaced by these.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_security_advisor as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# Canonical "already converged" live state: schedule on, Wed 04:15, defaultGroup=custom.
_CONVERGED_GET = {
    "enableSchedule": True,
    "weekday":        "3",          # Wed (Sun=0 .. Sat=6)
    "hour":           4,
    "minute":         15,
    "defaultGroup":   "custom",
    "scheduleTaskId": 2,             # READ-ONLY — must be stripped before SET
    "success":        True,          # synthetic — must be stripped before SET
}


def test_main_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.SA_CONF_API: {"get": dict(_CONVERGED_GET)}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", json.dumps(["system_health", "security"]),
        "--notify-email", "true",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def _set_input(captured, api):
    """Extract the Input envelope dict from a captured SET call (parses the
    single Input= form arg). All SecurityScan.Conf SETs wrap params in Input
    per the DSM API (validated 2026-06-01 from a UI HAR — flat params err 114)."""
    set_call = next(p for a, p in captured if a == api and "method=set" in p)
    input_args = [p for p in set_call if p.startswith("Input=")]
    assert len(input_args) == 1, "expected single Input= envelope: " + str(set_call)
    import json as _j
    return _j.loads(input_args[0][len("Input="):])


def test_main_drift_translates_day_and_enable(monkeypatch, capsys):
    """spec.day "Wed" must SET weekday="3"; spec.enable maps to enableSchedule.
    All params go inside an Input envelope (DSM SET requirement)."""
    drift_live = dict(_CONVERGED_GET)
    drift_live.update({"enableSchedule": False, "weekday": "1", "hour": 9, "minute": 0})
    fake, captured = _factory({m.SA_CONF_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("CHANGED")
    payload = _set_input(captured, m.SA_CONF_API)
    assert payload["enableSchedule"] is True
    assert payload["weekday"] == "3"
    assert payload["hour"] == 4
    assert payload["minute"] == 15


def test_main_strips_success_but_keeps_scheduleTaskId(monkeypatch, capsys):
    """`success` is a synthetic GET-only marker and must be stripped;
    `scheduleTaskId` LOOKS internal but DSM's SET actually requires it
    round-tripped (UI HAR 2026-06-01: omitting it → err 114). All fields
    are wrapped in an `Input` envelope on the wire."""
    drift_live = dict(_CONVERGED_GET)
    drift_live["weekday"] = "1"  # force drift so SET fires
    fake, captured = _factory({m.SA_CONF_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true",
    ])
    capsys.readouterr()
    set_call = next(p for a, p in captured
                    if a == m.SA_CONF_API and "method=set" in p)
    # `success` stripped
    assert not any(p.startswith("success=") for p in set_call), \
        "success must be stripped (synthetic GET marker): " + str(set_call)
    # All real fields go through one Input= envelope param, not flat key=val
    input_args = [p for p in set_call if p.startswith("Input=")]
    assert len(input_args) == 1, "expected single Input= envelope: " + str(set_call)
    import json as _j
    payload = _j.loads(input_args[0][len("Input="):])
    # scheduleTaskId IS in the envelope (round-tripped, required by SET)
    assert payload.get("scheduleTaskId") == 2, \
        "scheduleTaskId must round-trip (UI does — DSM 114s without it): " + str(payload)
    # `success` is NOT in the envelope
    assert "success" not in payload, str(payload)
    # The drift target IS in the envelope
    assert payload.get("weekday") == "3"


def test_main_preserves_unmanaged_keys_like_defaultGroup(monkeypatch, capsys):
    """`defaultGroup` is unmanaged HERE (categories follow-up) but must round-trip
    inside the Input envelope so we don't reset DSM's custom group profile."""
    drift_live = dict(_CONVERGED_GET, weekday="1", defaultGroup="custom")
    fake, captured = _factory({m.SA_CONF_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true",
    ])
    capsys.readouterr()
    payload = _set_input(captured, m.SA_CONF_API)
    assert payload.get("defaultGroup") == "custom"


def test_main_check_mode_does_not_apply(monkeypatch, capsys):
    drift_live = dict(_CONVERGED_GET, enableSchedule=False)
    fake, captured = _factory({m.SA_CONF_API: {"get": drift_live}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true", "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.SA_CONF_API and "method=set" in p for a, p in captured)


def test_day_validation_rejects_garbage(monkeypatch, capsys):
    fake, _ = _factory({m.SA_CONF_API: {"get": dict(_CONVERGED_GET)}})
    monkeypatch.setattr(m, "_exec", fake)
    try:
        m.main(["main", "--enable", "true", "--day", "Mango",
                "--hour", "4", "--minute", "15",
                "--categories", "[]", "--notify-email", "true"])
    except SystemExit as e:
        assert "Mango" in str(e) or "--day" in str(e)
    else:
        assert False, "should have raised SystemExit on bad --day"


def test_all_seven_weekdays_map_correctly(monkeypatch, capsys):
    """Sun..Sat must map to "0".."6" — confirms Unix-cron convention."""
    expected = {"Sun": "0", "Mon": "1", "Tue": "2", "Wed": "3",
                "Thu": "4", "Fri": "5", "Sat": "6"}
    for spec_day, dsm_str in expected.items():
        # current weekday = "0" so EVERY non-Sun spec triggers drift -> SET
        live = dict(_CONVERGED_GET, weekday="0")
        fake, captured = _factory({m.SA_CONF_API: {"get": live}})
        monkeypatch.setattr(m, "_exec", fake)
        m.main(["main", "--enable", "true", "--day", spec_day,
                "--hour", "4", "--minute", "15",
                "--categories", "[]", "--notify-email", "true"])
        capsys.readouterr()
        set_calls = [p for a, p in captured if a == m.SA_CONF_API
                     and any("method=set" in s for s in p)]
        if spec_day == "Sun":
            # no drift -> no SET
            assert not set_calls
        else:
            assert set_calls, "expected SET for " + spec_day
            # weekday lives inside the Input envelope, not as a flat form arg
            payload = _set_input([(m.SA_CONF_API, set_calls[0])], m.SA_CONF_API)
            assert payload["weekday"] == dsm_str, \
                spec_day + " should map to weekday=" + dsm_str


def test_categories_invalid_json_is_rejected_loudly():
    """`--categories` is deferred from APPLY but still VALIDATED — a malformed
    spec should fail fast at the helper rather than going silent."""
    try:
        m.main(["main", "--enable", "true", "--day", "Wed",
                "--hour", "4", "--minute", "15",
                "--categories", "not json", "--notify-email", "true"])
    except SystemExit as e:
        assert "categories" in str(e).lower() or "JSON" in str(e)
    else:
        assert False, "should have raised SystemExit on bad --categories"


def test_categories_must_be_list_not_dict():
    try:
        m.main(["main", "--enable", "true", "--day", "Wed",
                "--hour", "4", "--minute", "15",
                "--categories", '{"a": 1}', "--notify-email", "true"])
    except SystemExit as e:
        assert "list" in str(e).lower()
    else:
        assert False, "should have raised SystemExit"


# --- err 102 (API absent) — fail loudly (this surface CAN'T be silent-skipped) -
def test_err102_fails_loudly(monkeypatch, capsys):
    """Unlike `synology_external_access` which treats err 102 + desired-off as
    no-op, Security Advisor `enable=true` is a positive ask — if the API is
    absent we MUST fail loudly so the operator notices."""
    def fake(api, *params):
        if "method=get" in params:
            return {"success": False, "error": {"code": 102}}
        return {"success": True}
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["main", "--enable", "true", "--day", "Wed",
                 "--hour", "4", "--minute", "15",
                 "--categories", "[]", "--notify-email", "true"])
    assert rc == 1
    out = capsys.readouterr().out
    assert out.startswith("FAIL")
    assert "102" in out
    assert "API not present" in out


def test_string_weekday_no_type_drift(monkeypatch, capsys):
    """DSM stores weekday as a string-of-digit ("3") even though hour/minute are
    ints. The diff must not false-positive on the str-vs-str comparison."""
    fake, _ = _factory({m.SA_CONF_API: {"get": dict(_CONVERGED_GET, weekday="3")}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "main", "--enable", "true", "--day", "Wed", "--hour", "4", "--minute", "15",
        "--categories", "[]", "--notify-email", "true",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
