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
    fake, _ = _factory(
        {
            m.TERMINAL_API: {
                "get": {
                    "enable_ssh": True,
                    "ssh_port": 22,
                    "enable_telnet": False,
                    "enable_sftp": False,
                }
            }
        }
    )
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(
        [
            "terminal",
            "--ssh-enable",
            "true",
            "--ssh-port",
            "22",
            "--telnet-enable",
            "false",
            "--sftp-enable",
            "false",
        ]
    )
    assert rc == 0 and "OK no-change" in capsys.readouterr().out


def test_terminal_drift_disables_telnet(monkeypatch, capsys):
    """SFTP no longer goes through Terminal (it lives on
    SYNO.Core.FileServ.SFTP — synology_services). --sftp-enable still
    accepts the arg for backward-compat with the role task, but the
    value is dropped — only enable_ssh / ssh_port / enable_telnet flow
    into the SET payload."""
    fake, captured = _factory(
        {
            m.TERMINAL_API: {
                "get": {
                    "enable_ssh": True,
                    "ssh_port": 22,
                    "enable_telnet": True,
                }
            }
        }
    )
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(
        [
            "terminal",
            "--ssh-enable",
            "true",
            "--ssh-port",
            "22",
            "--telnet-enable",
            "false",
            "--sftp-enable",
            "false",
        ]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.TERMINAL_API and "method=set" in p)
    assert "enable_telnet=false" in set_call
    # v=3 is used (v=1 lacks ssh_port in the GET → spurious drift)
    assert "version=3" in set_call
    # SFTP must NOT be in the Terminal SET payload (wrong API entirely)
    assert not any("enable_sftp" in arg for arg in set_call), (
        "enable_sftp belongs on FileServ.SFTP, not Terminal: " + str(set_call)
    )


def test_terminal_check_mode_no_apply(monkeypatch, capsys):
    fake, captured = _factory(
        {
            m.TERMINAL_API: {
                "get": {
                    "enable_ssh": True,
                    "ssh_port": 22,
                    "enable_telnet": True,
                    "enable_sftp": True,
                }
            }
        }
    )
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(
        [
            "terminal",
            "--ssh-enable",
            "true",
            "--ssh-port",
            "22",
            "--telnet-enable",
            "false",
            "--sftp-enable",
            "false",
            "--check",
        ]
    )
    assert rc == 0
    assert capsys.readouterr().out.startswith("WOULD-CHANGE")
    assert not any(a == m.TERMINAL_API and "method=set" in p for a, p in captured)


def test_terminal_preserves_unmanaged_keys(monkeypatch, capsys):
    fake, captured = _factory(
        {
            m.TERMINAL_API: {
                "get": {
                    "enable_ssh": True,
                    "ssh_port": 22,
                    "enable_telnet": True,
                    "enable_sftp": False,
                    "snmp_unrelated_key": "preserve_me",
                }
            }
        }
    )
    monkeypatch.setattr(m, "_exec", fake)
    m.main(
        [
            "terminal",
            "--ssh-enable",
            "true",
            "--ssh-port",
            "22",
            "--telnet-enable",
            "false",
            "--sftp-enable",
            "false",
        ]
    )
    capsys.readouterr()
    set_call = next(p for a, p in captured if a == m.TERMINAL_API)
    assert 'snmp_unrelated_key="preserve_me"' in set_call


def test_terminal_port_change(monkeypatch, capsys):
    fake, captured = _factory(
        {
            m.TERMINAL_API: {
                "get": {
                    "enable_ssh": True,
                    "ssh_port": 22,
                    "enable_telnet": False,
                    "enable_sftp": False,
                }
            }
        }
    )
    monkeypatch.setattr(m, "_exec", fake)
    rc = m.main(
        [
            "terminal",
            "--ssh-enable",
            "true",
            "--ssh-port",
            "2222",
            "--telnet-enable",
            "false",
            "--sftp-enable",
            "false",
        ]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("CHANGED")
    set_call = next(p for a, p in captured if a == m.TERMINAL_API)
    assert "ssh_port=2222" in set_call


# --- sshd-drop-in (drop-in + main Include + AD-keys helper, single transaction) ---
def _redirect_paths(monkeypatch, tmp_path):
    """Redirect the three managed paths into tmp_path. Returns (dropin, main, helper)."""
    dropin = tmp_path / "10-krg-hardening.conf"
    main = tmp_path / "sshd_config"
    helper = tmp_path / "krg-ad-authkeys"
    monkeypatch.setattr(m, "SSHD_DROP_IN", str(dropin))
    monkeypatch.setattr(m, "SSHD_MAIN", str(main))
    monkeypatch.setattr(m, "AD_AUTHKEYS_PATH", str(helper))
    # The _FILE_MODES table is keyed on the production paths — re-key on tmp
    # paths so _atomic_write can still look up modes.
    monkeypatch.setattr(
        m,
        "_FILE_MODES",
        {
            str(helper): 0o755,
            str(dropin): 0o644,
            str(main): 0o644,
        },
    )
    return dropin, main, helper


def test_drop_in_render_disables_password_root():
    out = m._render_drop_in(allow_password=False, allow_root=False, allowed_algos="ssh-ed25519")
    assert "PasswordAuthentication no" in out
    assert "PermitRootLogin no" in out
    # OpenSSH 8.2 (DSM 7.3) requires the OLD name PubkeyAcceptedKeyTypes —
    # PubkeyAcceptedAlgorithms is a hard parse error there (introduced in 8.5).
    # Regression guard: the wrong name made the entire drop-in unloadable.
    assert "PubkeyAcceptedKeyTypes ssh-ed25519" in out
    assert "PubkeyAcceptedAlgorithms" not in out, (
        "8.2 cannot parse PubkeyAcceptedAlgorithms; use PubkeyAcceptedKeyTypes"
    )
    assert "HostKeyAlgorithms ssh-ed25519" in out
    # AuthorizedKeysCommand wires sshd to the AD-keys helper (required for AD
    # users to log in without password since they have no home dir on DSM).
    assert "AuthorizedKeysCommand " + m.AD_AUTHKEYS_PATH in out
    assert "AuthorizedKeysCommandUser root" in out


def test_drop_in_render_allows_when_relaxed():
    out = m._render_drop_in(allow_password=True, allow_root=True, allowed_algos="")
    assert "PasswordAuthentication yes" in out
    assert "PermitRootLogin yes" in out
    assert "PubkeyAcceptedKeyTypes" not in out  # empty algos -> omit
    # AuthorizedKeysCommand is unconditional — the drop-in always serves AD
    # keys, even when password auth is also allowed.
    assert "AuthorizedKeysCommand" in out


def test_ensure_include_block_prepends_once():
    """Idempotent: first call prepends INCLUDE_BLOCK, second is a no-op."""
    main = "PasswordAuthentication yes\nUsePAM yes\n"
    once = m._ensure_include_block(main)
    assert once.startswith(m.INCLUDE_BEGIN_MARKER)
    assert "Include /etc/ssh/sshd_config.d/*.conf" in once
    assert once.endswith(main)  # original content preserved verbatim
    twice = m._ensure_include_block(once)
    assert twice == once, "_ensure_include_block must be idempotent"


def test_ad_authkeys_helper_shape():
    """The helper must: take $1 (username), guard against shell-meta, and
    invoke `net ads search` for sshPublicKey. Regression guards for shell
    injection (DSM passes sshd's %u unescaped)."""
    s = m.AD_AUTHKEYS_SCRIPT
    assert s.startswith("#!/bin/sh\n")
    assert "sAMAccountName=$USER" in s
    assert "net ads search" in s
    assert "sshPublicKey" in s
    # Character-class guard against LDAP / shell injection.
    assert "[!A-Za-z0-9._-]" in s
    # No kinit — we rely on machine creds via secrets.tdb (root needed).
    assert "kinit" not in s


def test_drop_in_no_change(monkeypatch, capsys, tmp_path):
    """All three files already match desired → OK no-change, no shell calls."""
    dropin, main, helper = _redirect_paths(monkeypatch, tmp_path)
    dropin.write_text(m._render_drop_in(False, False, "ssh-ed25519"))
    helper.write_text(m.AD_AUTHKEYS_SCRIPT)
    main.write_text(m._ensure_include_block("PasswordAuthentication yes\n"))
    # No subprocess.run should be invoked when there's no change.
    runs = []
    monkeypatch.setattr(
        m.subprocess,
        "run",
        lambda c, *_, **__: (
            runs.append(c) or type("R", (), {"returncode": 0, "stderr": "", "stdout": ""})()
        ),
    )
    rc = m.main(
        [
            "sshd-drop-in",
            "--allow-password",
            "false",
            "--allow-root",
            "false",
            "--allowed-algos",
            "ssh-ed25519",
        ]
    )
    assert rc == 0 and "OK no-change" in capsys.readouterr().out
    assert runs == [], "no-change must skip sshd -t / systemctl restart"


def test_drop_in_check_mode_no_write(monkeypatch, capsys, tmp_path):
    """--check: report drift across the three files, write nothing."""
    dropin, main, helper = _redirect_paths(monkeypatch, tmp_path)
    rc = m.main(
        [
            "sshd-drop-in",
            "--allow-password",
            "false",
            "--allow-root",
            "false",
            "--allowed-algos",
            "ssh-ed25519",
            "--check",
        ]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert out.startswith("WOULD-CHANGE")
    assert not dropin.exists() and not main.exists() and not helper.exists()
    # All three target paths must appear in the drift summary so the operator
    # sees the full surface.
    payload = json.loads(out[len("WOULD-CHANGE ") :])
    assert str(dropin) in payload
    assert str(main) in payload
    assert str(helper) in payload


def test_drop_in_writes_validates_restarts(monkeypatch, capsys, tmp_path):
    """Happy path: all three files written, sshd -t OK, systemctl restart sshd OK.
    Validates the transaction order: writes → sshd -t → restart."""
    dropin, main, helper = _redirect_paths(monkeypatch, tmp_path)
    # Pre-populate main with a realistic DSM sshd_config so the Include block
    # gets prepended (rather than being the only content).
    main.write_text("PasswordAuthentication yes\nUsePAM yes\n")

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

    rc = m.main(
        [
            "sshd-drop-in",
            "--allow-password",
            "false",
            "--allow-root",
            "false",
            "--allowed-algos",
            "ssh-ed25519",
        ]
    )
    out = capsys.readouterr().out
    assert rc == 0 and out.startswith("CHANGED")
    # All three files landed.
    assert "PasswordAuthentication no" in dropin.read_text()
    assert "AuthorizedKeysCommand " + str(helper) in dropin.read_text()
    assert helper.read_text().startswith("#!/bin/sh")
    assert main.read_text().startswith(m.INCLUDE_BEGIN_MARKER)
    assert "PasswordAuthentication yes" in main.read_text(), (
        "Original sshd_config content must be preserved verbatim after the Include block"
    )
    # validation MUST come before restart; restart uses systemctl.
    sshd_idx = next(i for i, c in enumerate(runs) if c[0] == "sshd")
    restart_idx = next(i for i, c in enumerate(runs) if c[0] == "systemctl")
    assert sshd_idx < restart_idx
    assert runs[restart_idx] == ["systemctl", "restart", "sshd"]
    assert not any(c[0] == "synoservicectl" for c in runs)


def test_drop_in_validation_failure_rolls_back_all(monkeypatch, capsys, tmp_path):
    """If `sshd -t` fails AFTER atomic writes, ALL THREE files must be restored
    BEFORE any restart attempt. Critical safety property: a broken drop-in must
    never reach a running sshd."""
    dropin, main, helper = _redirect_paths(monkeypatch, tmp_path)
    old_dropin = "PasswordAuthentication yes\n"
    old_main = "PasswordAuthentication yes\nUsePAM yes\n"
    dropin.write_text(old_dropin)
    main.write_text(old_main)
    # helper doesn't exist before → must be removed (not restored to empty)

    class FakeCompleted:
        def __init__(self, rc, stderr=""):
            self.returncode = rc
            self.stderr = stderr
            self.stdout = ""

    def fake_run(cmd, *_, **__):
        if cmd[0] == "sshd":
            return FakeCompleted(1, "Bad configuration")
        return FakeCompleted(0)

    monkeypatch.setattr(m.subprocess, "run", fake_run)

    rc = m.main(
        [
            "sshd-drop-in",
            "--allow-password",
            "false",
            "--allow-root",
            "false",
            "--allowed-algos",
            "ssh-ed25519",
        ]
    )
    assert rc == 1
    assert capsys.readouterr().out.startswith("FAIL")
    # Pre-existing files restored verbatim.
    assert dropin.read_text() == old_dropin
    assert main.read_text() == old_main
    # Helper had no prior content → must be removed.
    assert not helper.exists(), "rollback must remove files that didn't exist pre-transaction"
