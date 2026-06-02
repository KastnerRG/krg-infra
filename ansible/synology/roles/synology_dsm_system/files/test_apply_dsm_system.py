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
    monkeypatch.setattr(m, "_exec", _exec_factory({
        "server_name": "e4e-nas", "gateway": "132.239.17.1",
        "dns_primary": "132.239.95.109", "dns_secondary": "1.1.1.1",
        "dns_manual": True, "ipv4_first": False,
    }))
    rc = m.main(["network", "--hostname", "e4e-nas",
                 "--gateway", "132.239.17.1",
                 "--dns-primary", "132.239.95.109",
                 "--dns-secondary", "1.1.1.1",
                 "--dns-manual", "true"])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_network_apply_hostname_drift(monkeypatch, capsys):
    """SET payload uses JSON-quoted string values (validated 2026-06-01:
    synowebapi --exec parses each key=value as JSON; bare `132.239.17.1`
    became float `132.239` and DSM rejected with err 4302). Asserts
    JSON-quoted form `server_name="e4e-nas"` not bare `server_name=e4e-nas`."""
    captured = []
    monkeypatch.setattr(m, "_exec", _exec_factory(
        {"server_name": "e4e_nas", "gateway": "132.239.17.1",
         "dns_primary": "132.239.95.109", "extra_unmanaged": "stays"},
        set_capture=captured))
    rc = m.main(["network", "--hostname", "e4e-nas"])
    assert rc == 0 and capsys.readouterr().out.startswith("CHANGED")
    api, params = captured[0]
    assert api == "SYNO.Core.Network" and "version=2" in params
    rest = set(params[2:])
    assert 'server_name="e4e-nas"' in rest                # JSON-quoted string
    assert 'extra_unmanaged="stays"' in rest              # unmanaged preserved + JSON-quoted
    assert 'gateway="132.239.17.1"' in rest               # unmanaged preserved + JSON-quoted


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
        "got: " + str(params))


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

    monkeypatch.setattr(m, "_pkg_is_installed",
                        _fake_installed(["ContainerManager", "OtherPkg"]))
    monkeypatch.setattr(m.subprocess, "run", tracking_fake)
    rc = m.main(["package-state", "--packages",
                 _json.dumps(["ContainerManager", "OtherPkg"])])
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
    rc = m.main(["package-state", "--packages",
                 _json.dumps(["ContainerManager"]), "--check"])
    assert rc == 0 and capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(c[1] == "start" for c in calls if len(c) >= 2), \
        "--check must NEVER call synopkg start"


def test_package_state_start_failure_returns_fail(monkeypatch, capsys):
    """synopkg start failure surfaces as FAIL, not silent pretend-success."""
    on = {"ContainerManager": False}
    monkeypatch.setattr(m, "_pkg_is_installed", _fake_installed(["ContainerManager"]))
    monkeypatch.setattr(m.subprocess, "run",
                        _synopkg_factory(on, start_results={"ContainerManager": False}))
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
    rc = m.main(["package-state", "--packages",
                 _json.dumps(["ContainerManager", "OtherPkg"])])
    captured = capsys.readouterr()
    assert rc == 0
    assert "OK no-change" in captured.out
    # Both missing packages produced a stderr warning, ANCHORED in install hint.
    assert "ContainerManager" in captured.err and "OtherPkg" in captured.err
    assert "terraform" in captured.err.lower() or "/var/packages" in captured.err
    # Crucially, no `synopkg start` calls (we never try to start a non-existent pkg).
    assert not any(len(c) >= 2 and c[1] == "start" for c in calls), \
        "must NOT call synopkg start on a missing package"


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
    rc = m.main(["package-state", "--packages",
                 _json.dumps(["ContainerManager", "VirtualMachineManager"])])
    captured = capsys.readouterr()
    assert rc == 0 and captured.out.startswith("CHANGED")
    assert "VirtualMachineManager" in captured.err  # warned about the missing one
    starts = [c for c in calls if len(c) >= 2 and c[1] == "start"]
    assert len(starts) == 1 and starts[0][2] == "ContainerManager"


def test_package_state_rejects_bad_json():
    import pytest as _pt
    with _pt.raises(SystemExit):
        m.main(["package-state", "--packages", '"not a list"'])
