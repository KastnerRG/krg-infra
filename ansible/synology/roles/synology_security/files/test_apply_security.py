"""Unit tests for apply_security.py — run with: pytest (no DSM needed)."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_security as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}

    return fake


def test_firewall_no_change(monkeypatch, capsys):
    monkeypatch.setattr(
        m, "_exec", _exec_factory({"enable_firewall": True, "profile_name": "default"})
    )
    rc = m.main(["firewall", "--enable", "true", "--profile", "default"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_firewall_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(
        m, "_exec", _exec_factory({"enable_firewall": False, "profile_name": "default"})
    )
    rc = m.main(["firewall", "--enable", "true", "--profile", "default", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "enable_firewall" in out


def test_firewall_apply_preserves_unmanaged(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(
        m,
        "_exec",
        _exec_factory(
            {"enable_firewall": False, "profile_name": "default", "extra_unmanaged": "stays"},
            set_capture=captured,
        ),
    )
    rc = m.main(["firewall", "--enable", "true"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    assert "enable_firewall=true" in rest and 'extra_unmanaged="stays"' in rest


def test_fw_conf_check(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"enable_port_check": False}))
    rc = m.main(["fw-conf", "--port-check", "true", "--check"])
    assert rc == 0 and "WOULD-CHANGE" in capsys.readouterr().out


def test_autoblock_apply_int_fields(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(
        m,
        "_exec",
        _exec_factory(
            {"enable": True, "attempts": 10, "within_mins": 60, "expire_day": 0},
            set_capture=captured,
        ),
    )
    rc = m.main(
        [
            "autoblock",
            "--enable",
            "true",
            "--attempts",
            "3",
            "--within-mins",
            "1440",
            "--expire-day",
            "7",
        ]
    )
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    rest = set(captured[0][1][2:])
    assert "attempts=3" in rest and "within_mins=1440" in rest and "expire_day=7" in rest


def test_autoblock_no_change_with_matching_values(monkeypatch, capsys):
    monkeypatch.setattr(
        m,
        "_exec",
        _exec_factory({"enable": True, "attempts": 3, "within_mins": 1440, "expire_day": 0}),
    )
    rc = m.main(
        [
            "autoblock",
            "--enable",
            "true",
            "--attempts",
            "3",
            "--within-mins",
            "1440",
            "--expire-day",
            "0",
        ]
    )
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_fail_on_unsuccessful_set(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"enable_firewall": False}, "success": True}
        return {"success": False, "error": {"code": 2001}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["firewall", "--enable", "true"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- H2: anti-lockout probe-profile subcommand ----------------------------------
def test_probe_profile_empty(monkeypatch, capsys):
    """An active profile with no rules → PROFILE-EMPTY (role refuses enable)."""

    def fake(api, *params):
        return {"success": True, "data": {"rules": []}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out == "PROFILE-EMPTY"


def test_probe_profile_has_rules(monkeypatch, capsys):
    """Rules present → PROFILE-HAS-RULES count=N (role proceeds)."""

    def fake(api, *params):
        return {"success": True, "data": {"rules": [{"id": 1}, {"id": 2}, {"id": 3}]}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    assert capsys.readouterr().out.strip() == "PROFILE-HAS-RULES count=3"


def test_probe_profile_unknown_shape(monkeypatch, capsys):
    """If DSM returns a shape we don't recognize → PROFILE-UNKNOWN (role refuses)."""

    def fake(api, *params):
        return {"success": True, "data": {"some_other_key": "weird"}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    assert capsys.readouterr().out.startswith("PROFILE-UNKNOWN")


def test_probe_profile_exec_failure_is_unknown(monkeypatch, capsys):
    """Any RuntimeError from _exec must be reported as PROFILE-UNKNOWN — never EMPTY (which would let the role proceed)."""

    def fake(api, *params):
        raise RuntimeError("connection refused")

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-profile", "--profile", "default"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("PROFILE-UNKNOWN")
    assert "PROFILE-EMPTY" not in out  # critical: must NOT be misclassified


# --- probe-geoip — read-only diagnostic ----------------------------------------
# do_geoip (Firewall.Geoip.set) was removed: the API descriptor has no `set`
# method, geoip lives as a per-rule attribute (set_type=geoip), and the
# Firewall.Rules.save_start CLI path segfaults on concrete rule objects. The
# enforcement is a documented manual UI step until the HTTP-webapi path lands.


def _geoip_probe_dispatcher(per_adapter_rules=None):
    """Build a fake _exec that dispatches on api+method for the probe.
    per_adapter_rules: dict[adapter_name] -> rules list (optional).
    """
    per_adapter_rules = per_adapter_rules or {}

    def fake(api, *params):
        method = next((p.split("=", 1)[1] for p in params if p.startswith("method=")), "")
        if api == "SYNO.Core.Security.Firewall.Geoip" and method == "list":
            return {
                "success": True,
                "data": {
                    "countries": [
                        {"country_code": "US", "country_search_name": "United States"},
                        {"country_code": "CA", "country_search_name": "Canada"},
                    ]
                },
            }
        if api == "SYNO.Core.Security.Firewall" and method == "get":
            return {"success": True, "data": {"enable_firewall": True, "profile_name": "default"}}
        if api == "SYNO.Core.Security.Firewall.Adapter" and method == "list":
            return {"success": True, "data": {"adapter_names": ["eth0", "global"]}}
        if api == "SYNO.Core.Security.Firewall.Rules" and method == "load":
            adapter = next(
                (p.split("=", 1)[1].strip('"') for p in params if p.startswith("adapter=")), ""
            )
            rules = per_adapter_rules.get(adapter, [])
            return {
                "success": True,
                "data": {
                    "policy": "deny" if rules else "allow",
                    "rules": rules or None,
                    "total": len(rules),
                },
            }
        return {"success": True, "data": {}}

    return fake


def test_probe_geoip_ok_shape(monkeypatch, capsys):
    """Probe surfaces countries_available + firewall + per_adapter + geoip_rule_count."""
    monkeypatch.setattr(m, "_exec", _geoip_probe_dispatcher())
    rc = m.main(["probe-geoip"])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    assert out.startswith("GEOIP-OK")
    import json as _j

    payload = _j.loads(out[len("GEOIP-OK ") :])
    assert payload["countries_available"] == 2
    assert payload["firewall"] == {"enable_firewall": True, "profile_name": "default"}
    assert {a["adapter"] for a in payload["per_adapter"]} == {"eth0", "global"}
    assert payload["geoip_rule_count"] == 0


def test_probe_geoip_counts_geoip_rules(monkeypatch, capsys):
    """A rule with set_type=geoip is counted (the field the operator should see set in DSM UI)."""
    rules = [{"enabled": True, "service_policy": "allow", "set_type": "geoip", "src": "US"}]
    monkeypatch.setattr(m, "_exec", _geoip_probe_dispatcher(per_adapter_rules={"eth0": rules}))
    rc = m.main(["probe-geoip"])
    assert rc == 0
    out = capsys.readouterr().out.strip()
    import json as _j

    payload = _j.loads(out[len("GEOIP-OK ") :])
    assert payload["geoip_rule_count"] == 1
    eth0 = next(a for a in payload["per_adapter"] if a["adapter"] == "eth0")
    assert eth0["total"] == 1 and eth0["policy"] == "deny"


def test_probe_geoip_exec_failure_is_unknown(monkeypatch, capsys):
    """Any RuntimeError mid-probe → GEOIP-UNKNOWN (never partial GEOIP-OK)."""

    def fake(api, *params):
        raise RuntimeError("api 114 unknown")

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["probe-geoip"])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("GEOIP-UNKNOWN") and "GEOIP-OK" not in out


def test_geoip_apply_subcommand_removed(monkeypatch, capsys):
    """The `geoip` subcommand was removed (calls a non-existent API);
    argparse must reject it so a stale invocation FAILs loudly rather than
    silently no-op'ing."""
    import pytest

    with pytest.raises(SystemExit) as exc:
        m.main(["geoip", "--enable", "true", "--countries", "US"])
    # argparse exits with code 2 on invalid choice
    assert exc.value.code == 2


# --- firewall-profile — HTTP webapi rule push (Profile.set + Profile.Apply) ---


class _FakeDSMSession:
    """Stand-in for dsm_http.DSMSession that records calls and returns canned data.

    Test seeds `_FakeDSMSession.current_profile` before the call; tests assert
    against `_FakeDSMSession.last_set_profile` + `last_apply_name` afterward.
    """

    current_profile = None
    last_set_profile = None
    last_apply_name = None
    raise_on_set = None  # if set, profile_set raises this exception

    def __init__(self, account=None, password=None, **kwargs):
        self.account = account
        self.password = password

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def profile_get(self, name):
        # Return a deep-copied dict so tests don't mutate the seed accidentally
        import copy

        return copy.deepcopy(_FakeDSMSession.current_profile)

    def profile_set(self, profile, applying=False):
        if _FakeDSMSession.raise_on_set:
            raise _FakeDSMSession.raise_on_set
        _FakeDSMSession.last_set_profile = profile
        return {}

    def profile_apply(self, name, **kw):
        _FakeDSMSession.last_apply_name = name
        return {"finish": True}


def _install_fake_dsm(monkeypatch):
    """Replace m.DSMSession with FakeDSMSession + m.DSMError with a local class.

    DSMSession is now defined IN apply_security (was a sibling module until
    we inlined it — ansible's `script:` only ships one file, so siblings
    couldn't be imported on the target). Tests monkeypatch the module attrs
    directly. Returns the DSMError class so tests can raise it.
    """

    class _DSMError(Exception):
        pass

    monkeypatch.setattr(m, "DSMSession", _FakeDSMSession)
    monkeypatch.setattr(m, "DSMError", _DSMError)
    _FakeDSMSession.current_profile = None
    _FakeDSMSession.last_set_profile = None
    _FakeDSMSession.last_apply_name = None
    _FakeDSMSession.raise_on_set = None
    return _DSMError


def _argv(desired, **overrides):
    """Build a firewall-profile argv list with sensible defaults."""
    import json as _j

    args = [
        "firewall-profile",
        "--account",
        overrides.get("account", "e4e-admin"),
        "--password",
        overrides.get("password", "pw"),
        "--profile-name",
        overrides.get("profile_name", "default"),
        "--desired",
        _j.dumps(desired),
    ]
    if overrides.get("apply"):
        args.append("--apply")
    if overrides.get("check"):
        args.append("--check")
    return args


def test_firewall_profile_no_change(monkeypatch, capsys):
    """Identical desired vs current → OK no-change, no set, no apply."""
    _install_fake_dsm(monkeypatch)
    rule = {
        "enable": True,
        "log": False,
        "name": "geoip-US-floor",
        "policy": "allow",
        "port_direction": "destination",
        "port_group": "all",
        "ports": "all",
        "protocol": "all",
        "source_ip_group": "geoip",
        "source_ip": "US",
    }
    _FakeDSMSession.current_profile = {
        "name": "default",
        "global": {"policy": "none", "rules": [rule]},
    }
    desired = {"global": {"policy": "none", "rules": [rule]}}
    rc = m.main(_argv(desired, apply=True))
    assert rc == 0
    assert "OK no-change" in capsys.readouterr().out
    assert _FakeDSMSession.last_set_profile is None
    assert _FakeDSMSession.last_apply_name is None


def test_firewall_profile_check_reports_drift_no_mutation(monkeypatch, capsys):
    """--check reports WOULD-CHANGE but does NOT call set/apply."""
    _install_fake_dsm(monkeypatch)
    _FakeDSMSession.current_profile = {
        "name": "default",
        "global": {"policy": "none", "rules": []},
        "eth0": {"policy": "allow", "rules": []},
    }
    desired = {
        "global": {
            "policy": "none",
            "rules": [
                {
                    "name": "geoip-US",
                    "policy": "allow",
                    "enable": True,
                    "log": False,
                    "port_direction": "destination",
                    "port_group": "all",
                    "ports": "all",
                    "protocol": "all",
                    "source_ip_group": "geoip",
                    "source_ip": "US",
                }
            ],
        }
    }
    rc = m.main(_argv(desired, check=True))
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("WOULD-CHANGE") and "global" in out
    assert _FakeDSMSession.last_set_profile is None


def test_firewall_profile_apply_preserves_unmanaged_adapters(monkeypatch, capsys):
    """eth1 is in current but NOT in desired — it must survive the merge."""
    _install_fake_dsm(monkeypatch)
    eth1_block = {
        "policy": "allow",
        "rules": [
            {
                "name": "user-manual",
                "policy": "allow",
                "enable": True,
                "log": False,
                "port_direction": "destination",
                "port_group": "all",
                "ports": "all",
                "protocol": "all",
                "source_ip_group": "all",
                "source_ip": "all",
            }
        ],
    }
    _FakeDSMSession.current_profile = {
        "name": "default",
        "eth1": eth1_block,
        "global": {"policy": "none", "rules": []},
    }
    desired = {
        "global": {
            "policy": "none",
            "rules": [
                {
                    "name": "geoip-US",
                    "policy": "allow",
                    "enable": True,
                    "log": False,
                    "port_direction": "destination",
                    "port_group": "all",
                    "ports": "all",
                    "protocol": "all",
                    "source_ip_group": "geoip",
                    "source_ip": "US",
                }
            ],
        }
    }
    rc = m.main(_argv(desired, apply=True))
    assert rc == 0 and "CHANGED" in capsys.readouterr().out
    assert _FakeDSMSession.last_set_profile["eth1"] == eth1_block
    assert _FakeDSMSession.last_set_profile["global"]["rules"][0]["name"] == "geoip-US"
    assert _FakeDSMSession.last_apply_name == "default"


def test_firewall_profile_anti_lockout_refuses_default_drop_no_allows(monkeypatch, capsys):
    """drop default (DSM's "deny") + zero allow rules anywhere = lockout. Must refuse."""
    _install_fake_dsm(monkeypatch)
    _FakeDSMSession.current_profile = {
        "name": "default",
        "eth0": {"policy": "allow", "rules": []},
        "global": {"policy": "none", "rules": []},
    }
    # Spec sets eth0 to drop with no allow rules in target → would lock out
    desired = {"eth0": {"policy": "drop", "rules": []}}
    rc = m.main(_argv(desired, apply=True))
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL anti-lockout")
    assert _FakeDSMSession.last_set_profile is None


def test_firewall_profile_anti_lockout_allows_when_allow_rule_present(monkeypatch, capsys):
    """drop default WITH an allow rule (covering admin source) = safe. Proceeds."""
    _install_fake_dsm(monkeypatch)
    _FakeDSMSession.current_profile = {
        "name": "default",
        "global": {"policy": "none", "rules": []},
        "eth0": {"policy": "allow", "rules": []},
    }
    # eth0 default-drop is safe because global has an allow rule covering it
    desired = {
        "eth0": {"policy": "drop", "rules": []},
        "global": {
            "policy": "none",
            "rules": [
                {
                    "name": "allow-trusted",
                    "policy": "allow",
                    "enable": True,
                    "log": False,
                    "port_direction": "destination",
                    "port_group": "all",
                    "ports": "all",
                    "protocol": "all",
                    "source_ip_group": "ip",
                    "source_ip": "192.168.1.0/24",
                }
            ],
        },
    }
    rc = m.main(_argv(desired, apply=True))
    assert rc == 0 and "CHANGED" in capsys.readouterr().out
    assert _FakeDSMSession.last_set_profile is not None


def test_firewall_profile_no_apply_flag_skips_commit(monkeypatch, capsys):
    """Without --apply, Profile.set runs but Profile.Apply does NOT."""
    _install_fake_dsm(monkeypatch)
    _FakeDSMSession.current_profile = {"name": "default", "global": {"policy": "none", "rules": []}}
    desired = {
        "global": {
            "policy": "none",
            "rules": [
                {
                    "name": "allow-trusted",
                    "policy": "allow",
                    "enable": True,
                    "log": False,
                    "port_direction": "destination",
                    "port_group": "all",
                    "ports": "all",
                    "protocol": "all",
                    "source_ip_group": "geoip",
                    "source_ip": "US",
                }
            ],
        }
    }
    rc = m.main(_argv(desired))  # no apply, no check
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED-NO-APPLY")
    assert _FakeDSMSession.last_set_profile is not None
    assert _FakeDSMSession.last_apply_name is None


def test_firewall_profile_no_password_fails_loud(monkeypatch, capsys):
    """No --password and no DSM_PASSWORD env → FAIL, no mutation."""
    _install_fake_dsm(monkeypatch)
    monkeypatch.delenv("DSM_PASSWORD", raising=False)
    rc = m.main(
        [
            "firewall-profile",
            "--account",
            "e4e-admin",
            "--profile-name",
            "default",
            "--desired",
            '{"global":{"policy":"deny","rules":[]}}',
            "--apply",
        ]
    )
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


def test_firewall_profile_dsm_error_surfaces_as_fail(monkeypatch, capsys):
    """A DSMError from profile_set bubbles up as FAIL (no apply attempted)."""
    DSMError = _install_fake_dsm(monkeypatch)
    _FakeDSMSession.current_profile = {"name": "default", "global": {"policy": "none", "rules": []}}
    _FakeDSMSession.raise_on_set = DSMError("Profile.set failed (code=120)")
    desired = {
        "global": {
            "policy": "none",
            "rules": [
                {
                    "name": "allow-trusted",
                    "policy": "allow",
                    "enable": True,
                    "log": False,
                    "port_direction": "destination",
                    "port_group": "all",
                    "ports": "all",
                    "protocol": "all",
                    "source_ip_group": "geoip",
                    "source_ip": "US",
                }
            ],
        }
    }
    rc = m.main(_argv(desired, apply=True))
    out = capsys.readouterr().out
    assert rc == 1 and "FAIL" in out and "120" in out
    assert _FakeDSMSession.last_apply_name is None  # never reached Apply
