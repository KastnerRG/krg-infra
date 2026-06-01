"""Unit tests for apply_ssh.py — run with: pytest (no DSM needed)."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import apply_ssh as m  # noqa: E402


def _factory(live):
    captured = []

    def fake(api, *params):
        if "method=get" in params:
            return {"data": dict(live[api]["get"]), "success": True}
        captured.append((api, params))
        return {"success": True}

    return fake, captured


# --- terminal -----------------------------------------------------------------
def test_terminal_no_change(monkeypatch, capsys):
    fake, _ = _factory({m.TERMINAL_API: {"get": {
        "enable_ssh": True, "ssh_port": 22,
        "enable_telnet": False, "enable_sftp": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "terminal", "--ssh-enable", "true", "--ssh-port", "22",
        "--telnet-enable", "false", "--sftp-enable", "false",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_terminal_drift_disables_telnet(monkeypatch, capsys):
    """SFTP no longer goes through Terminal (it lives on
    SYNO.Core.FileServ.SFTP — synology_services). --sftp-enable still
    accepts the arg for backward-compat with the role task, but the
    value is dropped — only enable_ssh / ssh_port / enable_telnet flow
    into the SET payload."""
    fake, captured = _factory({m.TERMINAL_API: {"get": {
        "enable_ssh": True, "ssh_port": 22, "enable_telnet": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "terminal", "--ssh-enable", "true", "--ssh-port", "22",
        "--telnet-enable", "false", "--sftp-enable", "false",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured
                    if a == m.TERMINAL_API and "method=set" in p)
    assert "enable_telnet=false" in set_call
    # v=3 is used (v=1 lacks ssh_port in the GET → spurious drift)
    assert "version=3" in set_call
    # SFTP must NOT be in the Terminal SET payload (wrong API entirely)
    assert not any("enable_sftp" in arg for arg in set_call), \
        "enable_sftp belongs on FileServ.SFTP, not Terminal: " + str(set_call)


def test_terminal_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory({m.TERMINAL_API: {"get": {
        "enable_ssh": True, "ssh_port": 22,
        "enable_telnet": True, "enable_sftp": True,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "terminal", "--ssh-enable", "true", "--ssh-port", "22",
        "--telnet-enable", "false", "--sftp-enable", "false", "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.TERMINAL_API and "method=set" in p for a, p in captured)


def test_terminal_preserves_unmanaged_keys(monkeypatch, capsys):
    fake, captured = _factory({m.TERMINAL_API: {"get": {
        "enable_ssh": True, "ssh_port": 22,
        "enable_telnet": True, "enable_sftp": False,
        "snmp_unrelated_key": "preserve_me",
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    m.main([
        "terminal", "--ssh-enable", "true", "--ssh-port", "22",
        "--telnet-enable", "false", "--sftp-enable", "false",
    ])
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.TERMINAL_API)
    assert "snmp_unrelated_key=preserve_me" in set_call


def test_terminal_port_change(monkeypatch, capsys):
    fake, captured = _factory({m.TERMINAL_API: {"get": {
        "enable_ssh": True, "ssh_port": 22,
        "enable_telnet": False, "enable_sftp": False,
    }}})
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main([
        "terminal", "--ssh-enable", "true", "--ssh-port", "2222",
        "--telnet-enable", "false", "--sftp-enable", "false",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.TERMINAL_API)
    assert "ssh_port=2222" in set_call


# --- sshd-drop-in -------------------------------------------------------------
def test_drop_in_render_disables_password_root():
    out = m._render_drop_in(allow_password=False, allow_root=False,
                            allowed_algos="ssh-ed25519")
    assert "PasswordAuthentication no" in out
    assert "PermitRootLogin no" in out
    assert "PubkeyAcceptedAlgorithms ssh-ed25519" in out
    assert "HostKeyAlgorithms ssh-ed25519" in out


def test_drop_in_render_allows_when_relaxed():
    out = m._render_drop_in(allow_password=True, allow_root=True, allowed_algos="")
    assert "PasswordAuthentication yes" in out
    assert "PermitRootLogin yes" in out
    assert "PubkeyAcceptedAlgorithms" not in out  # empty algos -> omit


def test_drop_in_no_change(monkeypatch, capsys, tmp_path):
    target = tmp_path / "10-krg-hardening.conf"
    desired = m._render_drop_in(False, False, "ssh-ed25519")
    target.write_text(desired)
    monkeypatch.setattr(m, "SSHD_DROP_IN", str(target))
    rc = m.main([
        "sshd-drop-in", "--allow-password", "false", "--allow-root", "false",
        "--allowed-algos", "ssh-ed25519",
    ])
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_drop_in_check_mode_no_write(monkeypatch, capsys, tmp_path):
    target = tmp_path / "10-krg-hardening.conf"
    monkeypatch.setattr(m, "SSHD_DROP_IN", str(target))
    rc = m.main([
        "sshd-drop-in", "--allow-password", "false", "--allow-root", "false",
        "--allowed-algos", "ssh-ed25519", "--check",
    ])
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not target.exists()


def test_drop_in_writes_validates_restarts(monkeypatch, capsys, tmp_path):
    """Happy path: file written, sshd -t OK, systemctl restart sshd OK."""
    target = tmp_path / "10-krg-hardening.conf"
    monkeypatch.setattr(m, "SSHD_DROP_IN", str(target))

    runs = []

    class FakeCompleted:
        def __init__(self, rc, stderr=""):
            self.returncode = rc
            self.stderr = stderr
            self.stdout = ""

    def fake_run(cmd, *_, **__):
        runs.append(cmd)
        return FakeCompleted(0)

    monkeypatch.setattr(m.subprocess, "run", fake_run)

    rc = m.main([
        "sshd-drop-in", "--allow-password", "false", "--allow-root", "false",
        "--allowed-algos", "ssh-ed25519",
    ])
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    assert target.exists()
    assert "PasswordAuthentication no" in target.read_text()
    # validation MUST come before restart; restart uses systemctl, NOT synoservicectl
    # (DSM 7.x is systemd-based; the earlier synoservicectl guess was from DSM 6 docs).
    sshd_idx = next(i for i, c in enumerate(runs) if c[0] == "sshd")
    restart_idx = next(i for i, c in enumerate(runs) if c[0] == "systemctl")
    assert sshd_idx < restart_idx
    # Specifically: `systemctl restart sshd` (not stop+start, not reload — the
    # drop-in needs sshd's full config reparse).
    restart_cmd = runs[restart_idx]
    assert restart_cmd == ["systemctl", "restart", "sshd"], \
        "expected `systemctl restart sshd`, got " + str(restart_cmd)
    # And the OLD synoservicectl is NEVER invoked anywhere (regression guard).
    assert not any(c[0] == "synoservicectl" for c in runs), \
        "synoservicectl is gone on DSM 7.x; the helper must not call it"


def test_drop_in_validation_failure_reverts(monkeypatch, capsys, tmp_path):
    """If sshd -t fails AFTER replacement, the script must restore old content."""
    target = tmp_path / "10-krg-hardening.conf"
    old = "PasswordAuthentication yes\n"   # the prior (bad-but-running) content
    target.write_text(old)
    monkeypatch.setattr(m, "SSHD_DROP_IN", str(target))

    class FakeCompleted:
        def __init__(self, rc, stderr=""):
            self.returncode = rc
            self.stderr = stderr
            self.stdout = ""

    def fake_run(cmd, *_, **__):
        # sshd -t returns non-zero (config invalid); systemctl restart never invoked
        if cmd[0] == "sshd":
            return FakeCompleted(1, "Bad configuration")
        return FakeCompleted(0)

    monkeypatch.setattr(m.subprocess, "run", fake_run)

    rc = m.main([
        "sshd-drop-in", "--allow-password", "false", "--allow-root", "false",
        "--allowed-algos", "ssh-ed25519",
    ])
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")
    # OLD content must be restored — running sshd's drop-in is never broken
    assert target.read_text() == old
