"""Unit tests for apply_dsm_system.py — run with: pytest (no DSM needed)."""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_dsm_system as m  # noqa: E402


def _exec_factory(get_data, set_capture=None):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        if set_capture is not None:
            set_capture.append((api, params))
        return {"success": True}

    return fake


def test_network_no_change(monkeypatch, capsys):
    monkeypatch.setattr(
        m,
        "_exec",
        _exec_factory(
            {
                "server_name": "e4e-nas",
                "gateway": "132.239.17.1",
                "dns_primary": "132.239.95.109",
                "dns_secondary": "1.1.1.1",
                "dns_manual": True,
                "ipv4_first": False,
            }
        ),
    )
    rc = m.main(
        [
            "network",
            "--hostname",
            "e4e-nas",
            "--gateway",
            "132.239.17.1",
            "--dns-primary",
            "132.239.95.109",
            "--dns-secondary",
            "1.1.1.1",
            "--dns-manual",
            "true",
        ]
    )
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_network_apply_hostname_drift(monkeypatch, capsys):
    """SET payload uses JSON-quoted string values (validated 2026-06-01:
    synowebapi --exec parses each key=value as JSON; bare `132.239.17.1`
    became float `132.239` and DSM rejected with err 4302). Asserts
    JSON-quoted form `server_name="e4e-nas"` not bare `server_name=e4e-nas`."""
    captured = []
    monkeypatch.setattr(
        m,
        "_exec",
        _exec_factory(
            {
                "server_name": "e4e_nas",
                "gateway": "132.239.17.1",
                "dns_primary": "132.239.95.109",
                "extra_unmanaged": "stays",
            },
            set_capture=captured,
        ),
    )
    rc = m.main(["network", "--hostname", "e4e-nas"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    api, params = captured[0]
    assert api == "SYNO.Core.Network" and "version=2" in params
    rest = set(params[2:])
    assert 'server_name="e4e-nas"' in rest  # JSON-quoted string
    assert 'extra_unmanaged="stays"' in rest  # unmanaged preserved + JSON-quoted
    assert 'gateway="132.239.17.1"' in rest  # unmanaged preserved + JSON-quoted


def test_network_check_reports_drift(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"server_name": "e4e_nas"}))
    rc = m.main(["network", "--hostname", "e4e-nas", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "server_name" in out


def test_network_fail(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {"server_name": "x"}, "success": True}
        return {"success": False, "error": {"code": 2001}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["network", "--hostname", "y"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


# --- package-defaults (the Terraform-provider prerequisite) ------------------
# The synology Terraform provider's synology_core_package calls
# SYNO.Core.Package.Setting.get and bails with "default volume empty" if
# default_vol is unset (synology-community/go-synology client.go).
# CRITICAL field-name regression guard: DSM 7.3 ONLY accepts `default_vol`
# on .set — other plausible param names (default_install_vol, volume, vol)
# return success: true but silently no-op (validated 2026-06-02 on e4e-nas).
def test_package_defaults_no_change(monkeypatch, capsys):
    monkeypatch.setattr(m, "_exec", _exec_factory({"default_vol": "/volume1"}))
    rc = m.main(["package-defaults", "--install-volume", "/volume1"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_package_defaults_drift_writes_default_vol(monkeypatch, capsys):
    """Empty current default_vol → SET payload must use exactly `default_vol`
    as the param key. Regression guard against future refactor flipping it to
    default_install_vol / volume / vol (DSM accepts those API calls but
    silently no-ops, leaving the install blocked)."""
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory({}, set_capture=captured))
    rc = m.main(["package-defaults", "--install-volume", "/volume1"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert len(captured) == 1
    api, params = captured[0]
    assert api == "SYNO.Core.Package.Setting"
    assert "method=set" in params
    # MUST be `default_vol` — not default_install_vol, not volume, not vol
    assert 'default_vol="/volume1"' in params, (
        "param key must be `default_vol` (DSM 7.3 silently no-ops on alternatives); "
        "got: " + str(params)
    )


def test_package_defaults_check_does_not_apply(monkeypatch, capsys):
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory({}, set_capture=captured))
    rc = m.main(["package-defaults", "--install-volume", "/volume2", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE")
    assert captured == [], "--check must never call .set"


def test_package_defaults_fail_propagates(monkeypatch, capsys):
    def fake(api, *params):
        if "method=get" in params:
            return {"data": {}, "success": True}
        return {"success": False, "error": {"code": 4302}}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["package-defaults", "--install-volume", "/volume1"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


def test_package_defaults_get_failure_yields_structured_fail(monkeypatch, capsys):
    """If SYNO.Core.Package.Setting.get returns {success:false,...} (auth
    timeout, permission denied, API rename), the subcommand must emit a
    structured FAIL line + exit 1 rather than raising KeyError on the
    missing `data` field. Regression guard against accidentally
    re-introducing the `["data"]` access without the success check."""

    def fake(api, *params):
        if "method=get" in params:
            return {"success": False, "error": {"code": 403, "errors": "permission denied"}}
        # SET path should never be reached if GET fails
        raise AssertionError("SET path called despite GET failure")

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["package-defaults", "--install-volume", "/volume1"])
    out = capsys.readouterr().out
    assert rc == 1 and out.startswith("FAIL ")
    import json as _j

    payload = _j.loads(out.split(" ", 1)[1])
    assert "GET failed" in payload["reason"]
    assert payload["response"]["success"] is False


# --- package-state (workaround for upstream provider Run-field bug) ----------
# `synology_core_package.run=true` is silently dropped by the upstream library;
# this subcommand converges named packages to started via `synopkg start`.
import json as _json  # noqa: E402


def _synopkg_factory(on_state, start_results=None):
    """Fake subprocess.run that mimics `synopkg is_onoff` + `synopkg start`.
    on_state: dict[pkg_name] -> bool (True = on); start mutates this in-place
    unless start_results overrides per-package start outcomes."""
    start_results = start_results or {}

    def fake(cmd, *_, **__):
        class R:
            returncode = 0
            stderr = ""
            stdout = ""

        r = R()
        if cmd[0] == m.SYNOPKG and cmd[1] == "is_onoff":
            pkg = cmd[2]
            r.returncode = 0 if on_state.get(pkg, False) else 1
        elif cmd[0] == m.SYNOPKG and cmd[1] == "start":
            pkg = cmd[2]
            outcome = start_results.get(pkg, True)
            if outcome:
                on_state[pkg] = True
                r.returncode = 0
                r.stdout = '{"action":"start","success":true,"package":"' + pkg + '"}'
            else:
                r.returncode = 1
                r.stderr = "synopkg start failed"
        return r

    return fake


def _fake_installed(installed_names):
    """Helper for tests that need a known set of "installed" packages.
    Apply with `monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(...))`."""
    s = set(installed_names)
    return lambda name: name in s


def test_package_state_no_change_when_all_running(monkeypatch, capsys):
    """All listed packages installed + already on → OK no-change, NO synopkg start calls."""
    on = {"ContainerManager": True}
    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager"]))
    monkeypatch.setattr(m.subprocess, "run", _synopkg_factory(on))
    rc = m.main(["package-state", "--packages", _json.dumps(["ContainerManager"])])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_package_state_starts_only_stopped_packages(monkeypatch, capsys):
    """Mixed state: started package skipped, stopped package gets started.
    Regression guard: the role's job is convergence, not unconditional start."""
    on = {"ContainerManager": False, "OtherPkg": True}
    calls = []
    base_fake = _synopkg_factory(on)

    def tracking_fake(cmd, *args, **kwargs):
        calls.append(list(cmd))
        return base_fake(cmd, *args, **kwargs)

    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager", "OtherPkg"]))
    monkeypatch.setattr(m.subprocess, "run", tracking_fake)
    rc = m.main(["package-state", "--packages", _json.dumps(["ContainerManager", "OtherPkg"])])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    # Exactly ONE start call, on ContainerManager (the one that was off)
    starts = [c for c in calls if len(c) >= 2 and c[1] == "start"]
    assert len(starts) == 1, "expected one start; got " + str(starts)
    assert starts[0][2] == "ContainerManager"


def test_package_state_check_does_not_start(monkeypatch, capsys):
    on = {"ContainerManager": False}
    calls = []
    base_fake = _synopkg_factory(on)

    def tracking_fake(cmd, *a, **k):
        calls.append(list(cmd))
        return base_fake(cmd, *a, **k)

    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager"]))
    monkeypatch.setattr(m.subprocess, "run", tracking_fake)
    rc = m.main(["package-state", "--packages", _json.dumps(["ContainerManager"]), "--check"])
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(c[1] == "start" for c in calls if len(c) >= 2), (
        "--check must NEVER call synopkg start"
    )


def test_package_state_start_failure_returns_fail(monkeypatch, capsys):
    """synopkg start failure surfaces as FAIL, not silent pretend-success."""
    on = {"ContainerManager": False}
    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager"]))
    monkeypatch.setattr(
        m.subprocess, "run", _synopkg_factory(on, start_results={"ContainerManager": False})
    )
    rc = m.main(["package-state", "--packages", _json.dumps(["ContainerManager"])])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


def test_package_state_skips_missing_packages_with_warning(monkeypatch, capsys):
    """Bootstrap case: a desired package isn't installed yet (terraform hasn't
    run). The role must warn on stderr + skip — NOT fail, NOT call `synopkg
    start` (which would emit a real error on a non-existent package)."""
    on = {}  # nothing on (also nothing installed)
    calls = []
    base_fake = _synopkg_factory(on)

    def tracking_fake(cmd, *a, **k):
        calls.append(list(cmd))
        return base_fake(cmd, *a, **k)

    # Nothing installed → every desired package missing.
    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed([]))
    monkeypatch.setattr(m.subprocess, "run", tracking_fake)
    rc = m.main(["package-state", "--packages", _json.dumps(["ContainerManager", "OtherPkg"])])
    captured = capsys.readouterr()
    assert rc == 0
    assert "OK no-change" in captured.out
    # Both missing packages produced a stderr warning, ANCHORED in install hint.
    assert "ContainerManager" in captured.err and "OtherPkg" in captured.err
    assert "terraform" in captured.err.lower() or "/var/packages" in captured.err
    # Crucially, no `synopkg start` calls (we never try to start a non-existent pkg).
    assert not any(len(c) >= 2 and c[1] == "start" for c in calls), (
        "must NOT call synopkg start on a missing package"
    )


def test_package_state_mixed_missing_and_drifting(monkeypatch, capsys):
    """Realistic case: one package present-but-off (drift → starts), one missing
    (warn → skip). Both signals must surface; only the present one is started."""
    on = {"ContainerManager": False}
    calls = []
    base_fake = _synopkg_factory(on)

    def tracking_fake(cmd, *a, **k):
        calls.append(list(cmd))
        return base_fake(cmd, *a, **k)

    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager"]))
    monkeypatch.setattr(m.subprocess, "run", tracking_fake)
    rc = m.main(
        ["package-state", "--packages", _json.dumps(["ContainerManager", "VirtualMachineManager"])]
    )
    captured = capsys.readouterr()
    assert rc == 0 and captured.out.startswith("CHANGED")
    assert "VirtualMachineManager" in captured.err  # warned about the missing one
    starts = [c for c in calls if len(c) >= 2 and c[1] == "start"]
    assert len(starts) == 1 and starts[0][2] == "ContainerManager"


def test_package_state_rejects_bad_json():
    import pytest as _pt

    with _pt.raises(SystemExit):
        m.main(["package-state", "--packages", '"not a list"'])


def test_package_state_rejects_malformed_json():
    """Malformed JSON (not just non-list) must SystemExit with a clear
    message rather than letting json.JSONDecodeError surface as a Python
    traceback (which Ansible would re-wrap unhelpfully)."""
    import pytest as _pt

    with _pt.raises(SystemExit) as exc:
        m.main(["package-state", "--packages", "this-is-not-json{"])
    assert "valid JSON" in str(exc.value)


# --- ntp (SYNO.Core.Region.NTP v1) -------------------------------------------
# Live GET shape, captured read-only from e4e-nas 2026-08-10. The clock-valued
# keys are the interesting part: they must never reach a SET payload.
_NTP_GET = {
    "date": "2026/8/10",
    "enable_ntp": "ntp",
    "hour": 20,
    "minute": 8,
    "now": "Mon Aug 10 20:08:37 2026\n",
    "second": 37,
    "server": "krg-ldap.krg.local",
    "timestamp": 1786417717,
    "timezone": "Pacific",
}


def _ntp_exec_factory(get_data, calls):
    """Fake _exec that records every call and answers get/set/sync."""

    def fake(api, *params):
        calls.append((api, params))
        if "method=get" in params:
            return {"data": dict(get_data), "success": True}
        return {"success": True}

    return fake


def test_ntp_no_change_still_forces_sync(monkeypatch, capsys):
    """The common case after the DC starts serving time: the configured server
    was ALREADY correct (the AD join set it), so there is no config drift — but
    the clock is still wrong because nothing was answering. DSM only runs
    ntpdate daily, so the task must force a sync anyway or the drift persists
    for up to another 24h."""
    calls = []
    monkeypatch.setattr(m, "_exec", _ntp_exec_factory(_NTP_GET, calls))
    rc = m.main(["ntp", "--server", "krg-ldap.krg.local"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    methods = [p for _, params in calls for p in params if p.startswith("method=")]
    assert methods == ["method=get", "method=sync"]


def test_ntp_check_mode_makes_no_write_calls(monkeypatch, capsys):
    """--check must neither set nor sync — sync steps the real clock."""
    calls = []
    monkeypatch.setattr(m, "_exec", _ntp_exec_factory(_NTP_GET, calls))
    rc = m.main(["ntp", "--server", "pool.ntp.org", "--check"])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("WOULD-CHANGE") and "pool.ntp.org" in out
    methods = [p for _, params in calls for p in params if p.startswith("method=")]
    assert methods == ["method=get"]


def test_ntp_set_payload_excludes_clock_fields(monkeypatch, capsys):
    """THE load-bearing assertion. Echoing the GET's date/hour/minute/second/
    now/timestamp back into a SET would ask DSM to set the time to an
    already-stale reading (the manual-time path, SYNONtpSetWithModifiedTime).
    A config write must never be able to step the clock. Config keys DO round
    trip — timezone included, which is how it survives untouched despite not
    being managed."""
    calls = []
    monkeypatch.setattr(m, "_exec", _ntp_exec_factory(_NTP_GET, calls))
    rc = m.main(["ntp", "--server", "krg-ldap.krg.local", "--enabled", "true"])
    assert rc == 0

    set_calls = [(api, params) for api, params in calls if "method=set" in params]
    assert len(set_calls) == 0, "no drift means no set"

    # Now with real drift, so a set actually happens.
    capsys.readouterr()  # drain the no-change run's output
    calls.clear()
    drifted = dict(_NTP_GET, server="pool.ntp.org")
    monkeypatch.setattr(m, "_exec", _ntp_exec_factory(drifted, calls))
    rc = m.main(["ntp", "--server", "krg-ldap.krg.local"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")

    (api, params) = [c for c in calls if "method=set" in c[1]][0]
    assert api == "SYNO.Core.Region.NTP"
    keys = {p.split("=", 1)[0] for p in params if "=" in p and not p.startswith("method")}
    for clock_key in m._NTP_CLOCK_KEYS:
        assert clock_key not in keys, "clock field %r must not reach a SET" % clock_key
    # Config fields round-trip; the desired server wins; strings stay JSON-quoted
    # (bare values get misparsed by synowebapi — see the network tests above).
    assert 'server="krg-ldap.krg.local"' in params
    assert 'enable_ntp="ntp"' in params
    assert 'timezone="Pacific"' in params


def test_ntp_sync_failure_warns_but_does_not_fail(monkeypatch, capsys):
    """A failed sync means the time source isn't answering right now — worth
    SAYING, but not a config-convergence failure. Hard-failing would take the
    whole NAS play red on a transient blip, and DSM retries daily."""

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(_NTP_GET), "success": True}
        if "method=sync" in params:
            return {"success": False, "error": {"code": 4800}}
        return {"success": True}

    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(["ntp", "--server", "krg-ldap.krg.local"])
    captured = capsys.readouterr()
    assert rc == 0 and "OK no-change" in captured.out
    assert "WARN" in captured.err and "4800" in captured.err


def test_ntp_get_failure_is_structured_fail(monkeypatch, capsys):
    """A failed GET must produce a FAIL line + rc 1, not a KeyError traceback
    that Ansible would re-wrap unhelpfully (same contract as package-defaults)."""
    monkeypatch.setattr(m, "_exec", lambda api, *p: {"success": False, "error": {"code": 105}})
    rc = m.main(["ntp", "--server", "krg-ldap.krg.local"])
    assert rc == 1 and capsys.readouterr().out.startswith("FAIL")


def test_ntp_refuses_to_disable(monkeypatch):
    """Disabling is unsupported: DSM's `enable_ntp` value for 'off' is
    unverified and manual-time mode is worse than drift. Must be a clear
    SystemExit, not a guessed write."""
    import pytest as _pt

    with _pt.raises(SystemExit) as exc:
        m.main(["ntp", "--server", "krg-ldap.krg.local", "--enabled", "false"])
    assert "not supported" in str(exc.value)
