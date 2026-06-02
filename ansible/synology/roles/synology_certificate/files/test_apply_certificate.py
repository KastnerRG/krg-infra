"""Unit tests for apply_certificate.py — pytest, no DSM needed."""
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import apply_certificate as m  # noqa: E402


# --- fixtures -----------------------------------------------------------------
def _le_args(**overrides):
    base = {
        "domain":               "e4e-nas.ucsd.edu",
        "email":                "ops@example.com",
        "sans_json":            "[]",
        "renewal_buffer_days":  30,
        "check":                False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _sd_args(**overrides):
    base = {
        "domain": "e4e-nas.ucsd.edu",
        "check":  False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _cert(domain, *, cid="xPpc1W", default=False, valid_till_dt=None, valid_till_raw=None):
    """Build a cert dict matching the SYNO.Core.Certificate.CRT.list shape."""
    if valid_till_raw is None:
        if valid_till_dt is None:
            valid_till_dt = datetime(2027, 5, 31, 4, 5, 39, tzinfo=timezone.utc)
        valid_till_raw = valid_till_dt.strftime("%b %d %H:%M:%S %Y") + " GMT"
    return {
        "id":         cid,
        "desc":       "",
        "subject":    {"common_name": domain},
        "is_default": default,
        "valid_till": valid_till_raw,
    }


def _stub_list(certs):
    """Make _list_certs return `certs` (no DSM call)."""
    return lambda: certs


# --- _parse_valid_till --------------------------------------------------------
def test_parse_valid_till_gmt():
    """Real DSM output we observed: 'May 31 04:05:39 2027 GMT'."""
    dt = m._parse_valid_till("May 31 04:05:39 2027 GMT")
    assert dt == datetime(2027, 5, 31, 4, 5, 39, tzinfo=timezone.utc)


def test_parse_valid_till_utc_suffix():
    """Same format, UTC suffix instead of GMT (defensive)."""
    assert m._parse_valid_till("Jan 1 00:00:00 2030 UTC") == \
        datetime(2030, 1, 1, tzinfo=timezone.utc)


def test_parse_valid_till_empty_returns_none():
    assert m._parse_valid_till("") is None
    assert m._parse_valid_till(None) is None


def test_parse_valid_till_garbage_returns_none():
    """Unparseable input → None (caller treats as 'unknown → re-issue')."""
    assert m._parse_valid_till("not a date") is None


# --- _find_by_domain ----------------------------------------------------------
def test_find_by_domain_returns_match():
    certs = [_cert("a.example"), _cert("e4e-nas.ucsd.edu", cid="abc123")]
    found = m._find_by_domain(certs, "e4e-nas.ucsd.edu")
    assert found["id"] == "abc123"


def test_find_by_domain_returns_none_when_missing():
    certs = [_cert("a.example"), _cert("b.example")]
    assert m._find_by_domain(certs, "missing.example") is None


def test_find_by_domain_refuses_ambiguity():
    """Multiple certs sharing a common_name must NOT be silently picked.
    Manual rotation residue is the typical cause; surface it loudly."""
    certs = [_cert("dup.example", cid="aaaaaa"), _cert("dup.example", cid="bbbbbb")]
    with pytest.raises(RuntimeError) as exc:
        m._find_by_domain(certs, "dup.example")
    assert "multiple" in str(exc.value).lower()


# --- letsencrypt-create -------------------------------------------------------
def test_letsencrypt_create_no_change_when_cert_exists_with_buffer(monkeypatch, capsys):
    """Cert exists + expires well outside the buffer → OK no-change.
    The DSM auto-renewer handles cert freshness; the role steps aside."""
    far_future = m._now_utc() + timedelta(days=300)
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("e4e-nas.ucsd.edu",
                                                           valid_till_dt=far_future)]))
    rc = m.do_letsencrypt_create(_le_args())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_letsencrypt_create_reissues_when_within_buffer(monkeypatch, capsys):
    """Cert exists but expires inside renewal_buffer_days → CHANGED.
    Safety net for silently-broken DSM auto-renew."""
    near = m._now_utc() + timedelta(days=10)
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("e4e-nas.ucsd.edu",
                                                           valid_till_dt=near)]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_letsencrypt_create(_le_args(renewal_buffer_days=30))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "expiring" in payload["reason"]
    # The CHANGED path called LE.create with the wizard-confirmed param
    # shape: desc + domain_name + email (NOT `domain`). Empty SAN list
    # short-circuits — no SAN_list param sent. See do_letsencrypt_create
    # docstring for the wizard-capture reference.
    assert len(calls) == 1
    api, *params = calls[0]
    assert api == m.LE_API
    assert "method=create" in params
    assert 'desc="e4e-nas.ucsd.edu"' in params
    assert 'domain_name="e4e-nas.ucsd.edu"' in params
    assert 'email="ops@example.com"' in params
    assert not any(p.startswith("SAN_list=") for p in params), \
        "empty SAN list must NOT send a SAN_list param"
    assert not any(p.startswith("domain=") for p in params), \
        "wizard uses `domain_name=`, not `domain=` — regression guard"


def test_letsencrypt_create_issues_when_missing(monkeypatch, capsys):
    """No matching cert → CHANGED (first-bring-up issuance)."""
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert("unrelated.example")]))
    monkeypatch.setattr(m, "_exec", lambda *args: {"success": True})
    rc = m.do_letsencrypt_create(_le_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["reason"] == "no cert for domain"


def test_letsencrypt_create_check_mode_doesnt_issue(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs", _stub_list([]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_letsencrypt_create(_le_args(check=True))
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE ")
    assert calls == [], "--check must NOT call SYNO.Core.Certificate.LetsEncrypt.create"


def test_letsencrypt_create_reissues_on_unparseable_valid_till(monkeypatch, capsys):
    """If valid_till is garbage / missing, defensive re-issue rather than
    no-op. Better a redundant LE issuance than a silently-expired cert."""
    bad = _cert("e4e-nas.ucsd.edu")
    bad["valid_till"] = "not a date"
    monkeypatch.setattr(m, "_list_certs", _stub_list([bad]))
    monkeypatch.setattr(m, "_exec", lambda *args: {"success": True})
    rc = m.do_letsencrypt_create(_le_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "unparseable" in payload["reason"]


def test_letsencrypt_create_propagates_le_failure(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs", _stub_list([]))
    monkeypatch.setattr(m, "_exec",
                        lambda *args: {"success": False, "error": {"code": 5400}})
    rc = m.do_letsencrypt_create(_le_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


def test_letsencrypt_create_fails_clean_on_list_failure(monkeypatch, capsys):
    """If the GET fails (auth timeout / permission), report structured FAIL
    not a KeyError traceback. Same defense as do_package_defaults on #102."""
    monkeypatch.setattr(m, "_list_certs", lambda: None)
    rc = m.do_letsencrypt_create(_le_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


def test_letsencrypt_create_rejects_ambiguous_duplicates(monkeypatch, capsys):
    """Two certs sharing common_name → FAIL with the ids surfaced."""
    monkeypatch.setattr(m, "_list_certs", _stub_list([
        _cert("e4e-nas.ucsd.edu", cid="aaaaaa"),
        _cert("e4e-nas.ucsd.edu", cid="bbbbbb"),
    ]))
    rc = m.do_letsencrypt_create(_le_args())
    out = capsys.readouterr().out
    assert rc == 1 and "multiple" in out


def test_letsencrypt_create_rejects_bad_sans_json(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs", _stub_list([]))
    # Not check mode (rejection happens after the check guard).
    rc = m.do_letsencrypt_create(_le_args(sans_json='"not-a-list"'))
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


# --- set-default --------------------------------------------------------------
def test_set_default_no_change_when_already_default(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert("e4e-nas.ucsd.edu", default=True)]))
    rc = m.do_set_default(_sd_args())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_set_default_binds_when_not_default(monkeypatch, capsys):
    """The SET call shape is wizard-captured (DSM 7.3 e4e-nas 2026-06-02):
    SYNO.Core.Certificate.CRT method=set as_default=true desc=<domain> id=<cert_id>
    — NOT method=set_default (which DSM rejects with code 103). Regression
    guard against re-introducing the wrong method/param shape."""
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert("e4e-nas.ucsd.edu", cid="zzz123",
                                          default=False)]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_set_default(_sd_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    assert len(calls) == 1
    api, *params = calls[0]
    assert api == m.CRT_API
    assert "method=set" in params
    assert "as_default=true" in params
    assert 'desc="e4e-nas.ucsd.edu"' in params
    assert 'id="zzz123"' in params
    # Regression guard: the WRONG shape (`method=set_default`) must NOT
    # appear; DSM returns code 103 for it.
    assert not any(p == "method=set_default" for p in params)


def test_set_default_fails_when_cert_missing_on_apply(monkeypatch, capsys):
    """Apply mode: ordering bug (set-default before letsencrypt-create) → FAIL."""
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("unrelated.example")]))
    rc = m.do_set_default(_sd_args())
    out = capsys.readouterr().out
    assert rc == 1 and "no cert for domain" in out


def test_set_default_reports_planned_when_cert_missing_in_check(monkeypatch, capsys):
    """--check mode on a fresh box: `letsencrypt-create --check` deliberately
    doesn't issue, so set-default's prereq is missing. That's expected dry-run
    shape, not a bug — report WOULD-CHANGE (the binding-after-issuance plan)."""
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("unrelated.example")]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_set_default(_sd_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["domain"] == "e4e-nas.ucsd.edu"
    assert "letsencrypt-create" in payload["reason"]
    assert calls == [], "--check must NOT call SYNO.Core.Certificate.CRT.set"


def test_set_default_check_mode_doesnt_bind(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert("e4e-nas.ucsd.edu", default=False)]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_set_default(_sd_args(check=True))
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE ")
    assert calls == []


# --- bind-services ------------------------------------------------------------
def _bs_args(**overrides):
    base = {
        "domain":         "e4e-nas.ucsd.edu",
        "bindings_json":  '[{"service":"default","subscriber":"system"}]',
        "check":          False,
    }
    base.update(overrides)
    return type("A", (), base)()


def _cert_with_services(domain, *, cid, services):
    c = _cert(domain, cid=cid)
    c["services"] = services
    return c


def test_bind_services_no_change_when_already_bound(monkeypatch, capsys):
    """Target cert already has the desired (service, subscriber) → no-op."""
    le_cert = _cert_with_services("e4e-nas.ucsd.edu", cid="LE001", services=[
        {"display_name": "DSM Desktop Service", "service": "default",
         "subscriber": "system", "isPkg": False, "owner": "root"},
    ])
    monkeypatch.setattr(m, "_list_certs", _stub_list([le_cert]))
    rc = m.do_bind_services(_bs_args())
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_bind_services_migrates_from_other_cert(monkeypatch, capsys):
    """Service is currently bound to a DIFFERENT cert → emit Service.set
    with old_id + id. Verifies the wizard-captured shape: nested `service`
    object + old_id + id."""
    factory = _cert_with_services("synology", cid="OLD9", services=[
        {"display_name": "DSM Desktop Service", "service": "default",
         "subscriber": "system", "isPkg": False, "owner": "root"},
    ])
    le_cert = _cert_with_services("e4e-nas.ucsd.edu", cid="LE001", services=[])
    monkeypatch.setattr(m, "_list_certs", _stub_list([factory, le_cert]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True,
                                                             "data": {"restart_httpd": False}})
    rc = m.do_bind_services(_bs_args())
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED ")
    payload = json.loads(out.split(" ", 1)[1])
    assert payload["bindings_to_set"] == 1
    assert payload["target_cert_id"] == "LE001"
    # Verify the POST shape:
    assert len(calls) == 1
    api, *params = calls[0]
    assert api == m.SERVICE_API
    assert "method=set" in params
    settings_param = [p for p in params if p.startswith("settings=")][0]
    settings = json.loads(settings_param[len("settings="):])
    assert settings == [{
        "service": {
            "display_name": "DSM Desktop Service",
            "isPkg":        False,
            "owner":        "root",
            "service":      "default",
            "subscriber":   "system",
        },
        "old_id": "OLD9",
        "id":     "LE001",
    }]


def test_bind_services_skips_missing_service_with_warning(monkeypatch, capsys):
    """A binding for a service DSM doesn't expose → warn + skip, no FAIL.
    DSM service catalogue varies by enabled packages; an unenabled FTPS
    shouldn't break cert binding for the rest."""
    le_cert = _cert_with_services("e4e-nas.ucsd.edu", cid="LE001", services=[])
    monkeypatch.setattr(m, "_list_certs", _stub_list([le_cert]))
    rc = m.do_bind_services(_bs_args(
        bindings_json='[{"service":"phantom","subscriber":"nobody"}]'))
    captured = capsys.readouterr()
    assert rc == 0 and "OK no-change" in captured.out
    assert "phantom" in captured.err and "skipping" in captured.err


def test_bind_services_check_mode_doesnt_post(monkeypatch, capsys):
    factory = _cert_with_services("synology", cid="OLD9", services=[
        {"display_name": "DSM Desktop Service", "service": "default",
         "subscriber": "system", "isPkg": False, "owner": "root"},
    ])
    le_cert = _cert_with_services("e4e-nas.ucsd.edu", cid="LE001", services=[])
    monkeypatch.setattr(m, "_list_certs", _stub_list([factory, le_cert]))
    calls = []
    monkeypatch.setattr(m, "_exec",
                        lambda *args: calls.append(args) or {"success": True})
    rc = m.do_bind_services(_bs_args(check=True))
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE ")
    assert calls == [], "--check must NOT call Certificate.Service.set"


def test_bind_services_check_mode_plans_when_cert_missing(monkeypatch, capsys):
    """Same dry-run safety pattern as set-default: in check mode, a
    missing target cert is reported as WOULD-CHANGE (letsencrypt-create
    would issue it on apply), not FAIL."""
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("unrelated.example")]))
    rc = m.do_bind_services(_bs_args(check=True))
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE ")
    payload = json.loads(out.split(" ", 1)[1])
    assert "letsencrypt-create" in payload["reason"]


def test_bind_services_fails_when_cert_missing_on_apply(monkeypatch, capsys):
    """Apply mode: ordering bug (bind-services before letsencrypt-create)
    → clean FAIL."""
    monkeypatch.setattr(m, "_list_certs", _stub_list([_cert("unrelated.example")]))
    rc = m.do_bind_services(_bs_args())
    out = capsys.readouterr().out
    assert rc == 1 and "no cert for domain" in out


def test_bind_services_propagates_api_failure(monkeypatch, capsys):
    factory = _cert_with_services("synology", cid="OLD9", services=[
        {"display_name": "X", "service": "default", "subscriber": "system",
         "isPkg": False, "owner": "root"},
    ])
    le_cert = _cert_with_services("e4e-nas.ucsd.edu", cid="LE001", services=[])
    monkeypatch.setattr(m, "_list_certs", _stub_list([factory, le_cert]))
    monkeypatch.setattr(m, "_exec",
                        lambda *args: {"success": False, "error": {"code": 5503}})
    rc = m.do_bind_services(_bs_args())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


def test_bind_services_rejects_bad_json(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs", _stub_list([]))
    rc = m.do_bind_services(_bs_args(bindings_json='"not a list"'))
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL ")


def test_bind_services_rejects_malformed_binding(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert_with_services("e4e-nas.ucsd.edu",
                                                        cid="LE001", services=[])]))
    rc = m.do_bind_services(_bs_args(
        bindings_json='[{"service":"default"}]'))  # missing `subscriber`
    out = capsys.readouterr().out
    assert rc == 1 and "subscriber" in out


# --- list (read-only debug + drift export) ------------------------------------
def test_list_trims_to_stable_fields(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs",
                        _stub_list([_cert("e4e-nas.ucsd.edu", cid="abc", default=True)]))
    rc = m.do_list(type("A", (), {})())
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload == [{
        "id":          "abc",
        "desc":        "",
        "common_name": "e4e-nas.ucsd.edu",
        "is_default":  True,
        "valid_till":  "May 31 04:05:39 2027 GMT",
    }]


def test_list_fails_clean_on_api_error(monkeypatch, capsys):
    monkeypatch.setattr(m, "_list_certs", lambda: None)
    rc = m.do_list(type("A", (), {})())
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")


# --- argparse plumbing --------------------------------------------------------
def test_main_dispatches_letsencrypt_create(monkeypatch, capsys):
    monkeypatch.setattr(m, "do_letsencrypt_create",
                        lambda a: (print("OK no-change") or 0))
    rc = m.main([
        "letsencrypt-create",
        "--domain", "e4e-nas.ucsd.edu",
        "--email", "ops@example.com",
        "--renewal-buffer-days", "30",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_main_dispatches_set_default(monkeypatch, capsys):
    monkeypatch.setattr(m, "do_set_default",
                        lambda a: (print("OK no-change") or 0))
    rc = m.main(["set-default", "--domain", "e4e-nas.ucsd.edu"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
