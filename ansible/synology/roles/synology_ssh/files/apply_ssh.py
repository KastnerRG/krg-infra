#!/usr/bin/env python3
"""Apply DSM Terminal config + sshd_config hardening drop-in idempotently.

Subcommands:
  terminal      SYNO.Core.Terminal set (v1) — ssh.enable + ssh.port + telnet.enable +
                sftp.enable. FULL-OBJECT (partial = err 2001): GET → overlay → SET.
  sshd-drop-in  Configure three coupled files as ONE transaction:
                  (a) /etc/ssh/sshd_config.d/10-krg-hardening.conf — hardening
                  (b) /etc/ssh/sshd_config — prepend `Include /etc/ssh/sshd_config.d/*.conf`
                      (DSM ships sshd_config without an Include — without this
                      prepend, the drop-in is orphaned)
                  (c) /usr/local/bin/krg-ad-authkeys — AuthorizedKeysCommand helper
                      that fetches sshPublicKey from AD via `net ads search`
                Atomic-writes all three, validates with `sshd -t`, rolls back
                ALL on validation failure (so the running daemon never reads a
                broken config), restarts sshd via `systemctl restart sshd` only
                on change. DSM 7.x is systemd-based and `sshd.service` is a
                standard OpenBSD-style unit. DSM has no UI toggle for these
                settings; `template:`/`copy:` don't work on DSM's python 3.8
                (below ansible's module floor), so this script ships the bytes.

Invoked by the synology_ssh ansible role via the `script` module.
Prints OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip OUT_KEYS
on first-apply drift):
  ssh.enable        -> enable_ssh
  ssh.port          -> ssh_port
  telnet.enable     -> enable_telnet
  sftp.enable       -> enable_sftp
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

WEBAPI = "/usr/syno/bin/synowebapi"
TERMINAL_API = "SYNO.Core.Terminal"
# DSM 7.3 Terminal: minVersion=1, maxVersion=3. v=1 GET returns only
# {enable_ssh, enable_telnet, forbid_console} — no ssh_port. v=3 returns
# those plus {ssh_port, ssh_cipher, ssh_kex, ssh_mac}. Using v=3 so the
# ssh_port diff has a real current value to compare against (otherwise
# current.get("ssh_port") is None, drift fires every run → CHANGED on
# idempotent re-applies).
TERMINAL_VER = 3
SSHD_DROP_IN = "/etc/ssh/sshd_config.d/10-krg-hardening.conf"
SSHD_MAIN = "/etc/ssh/sshd_config"
AD_AUTHKEYS_PATH = "/usr/local/bin/krg-ad-authkeys"

OUT_KEYS = {
    "ssh_enable":    "enable_ssh",
    "ssh_port":      "ssh_port",
    "telnet_enable": "enable_telnet",
    # sftp_enable lives on SYNO.Core.FileServ.SFTP, NOT SYNO.Core.Terminal.
    # Pushing it via Terminal SET was a silent no-op, and the GET-diff saw
    # current=null vs desired=false every run → false-positive CHANGED.
    # SFTP belongs to synology_services.
}


def _exec(api, *params):
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + api, *params],
        capture_output=True, text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _args_from(data):
    args = []
    for key, val in data.items():
        if val is None:
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif isinstance(val, (dict, list)):
            val = json.dumps(val)
        elif isinstance(val, str):
            # synowebapi --exec parses key=value as JSON. Bare strings like
            # /volume1 or 132.239.17.1 are invalid JSON tokens; DSM either
            # drops them (3103 "missing field") or truncates them (4302).
            # JSON-quote so DSM gets the exact string. Validated 2026-06-01.
            val = json.dumps(val)
        args.append("{}={}".format(key, val))
    return args


def _result(drift, check, apply_fn):
    if not drift:
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- terminal (SYNO.Core.Terminal, full-object) -----------------------------------
def do_terminal(a):
    desired = {
        OUT_KEYS["ssh_enable"]:    _bool(a.ssh_enable),
        OUT_KEYS["ssh_port"]:      int(a.ssh_port),
        OUT_KEYS["telnet_enable"]: _bool(a.telnet_enable),
    }
    current = _exec(TERMINAL_API, "version=%d" % TERMINAL_VER, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(TERMINAL_API, "version=%d" % TERMINAL_VER, "method=set",
                     *_args_from(current))

    return _result(drift, a.check, apply)


# --- sshd-drop-in (drop-in + main-config Include + AD-keys helper) ----------------
# OpenSSH-version note: DSM 7.3 ships OpenSSH 8.2p1 (verified 2026-06-01).
# `PubkeyAcceptedAlgorithms` was introduced in 8.5 — on 8.2 it's a hard parse
# error (`Bad configuration option: PubkeyAcceptedAlgorithms` → drop-in is
# rejected). The older name `PubkeyAcceptedKeyTypes` works on 8.2 AND on 8.5+
# (kept as a backwards-compat alias). Using the old name is the safe choice.
SSHD_TEMPLATE = """\
# Managed by Ansible (krg-infra synology_ssh) — DO NOT EDIT.
# Mirrors ansible/roles/ssh_hardening/templates/10-krg-hardening.conf.j2 and
# nix/profiles/base.nix services.openssh.settings. DSM's UI has no toggle for
# these settings, so they live here. A DSM major update can REVERT this file
# AND the main-config Include directive — re-apply synology_base after upgrades.

PasswordAuthentication {pw}
PermitRootLogin {root}
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
{algos}AuthorizedKeysCommand {ad_authkeys}
AuthorizedKeysCommandUser root
"""


def _render_drop_in(allow_password, allow_root, allowed_algos):
    algos = ""
    if allowed_algos:
        # PubkeyAcceptedKeyTypes (NOT PubkeyAcceptedAlgorithms — see version note above).
        algos = ("PubkeyAcceptedKeyTypes " + allowed_algos + "\n"
                 "HostKeyAlgorithms " + allowed_algos + "\n")
    return SSHD_TEMPLATE.format(
        pw="yes" if allow_password else "no",
        root="yes" if allow_root else "no",
        algos=algos,
        ad_authkeys=AD_AUTHKEYS_PATH,
    )


# --- main /etc/ssh/sshd_config — Include directive at top -------------------------
# DSM ships sshd_config without an `Include` directive, so the drop-in is
# orphaned. We prepend our own Include block at the top so OpenSSH's first-wins
# semantics apply our PasswordAuthentication=no BEFORE the main file's
# PasswordAuthentication=yes further down. Idempotent via marker detection.
INCLUDE_BEGIN_MARKER = "# --- BEGIN KRG-MANAGED Include (synology_ssh) ---"
INCLUDE_END_MARKER = "# --- END KRG-MANAGED Include (synology_ssh) ---"
INCLUDE_BLOCK = (INCLUDE_BEGIN_MARKER + "\n"
                 "# DSM ships sshd_config without an `Include` directive, leaving the drop-in at\n"
                 "# /etc/ssh/sshd_config.d/*.conf orphaned. Prepended at the top so first-wins\n"
                 "# semantics give the drop-in's PasswordAuthentication=no priority over the\n"
                 "# `PasswordAuthentication yes` line further down in this file.\n"
                 "Include /etc/ssh/sshd_config.d/*.conf\n"
                 + INCLUDE_END_MARKER + "\n\n")


def _ensure_include_block(content):
    """Idempotent: prepend INCLUDE_BLOCK iff our marker isn't already present."""
    if INCLUDE_BEGIN_MARKER in content:
        return content
    return INCLUDE_BLOCK + content


# --- AD-keys helper (/usr/local/bin/krg-ad-authkeys) ------------------------------
# sshd's AuthorizedKeysCommand. Looks up the sshPublicKey attribute on
# sAMAccountName=$1 in KRG.LOCAL via `net ads search`, which uses the machine
# account's secret in /var/lib/samba/private/secrets.tdb (root-only — that's
# why AuthorizedKeysCommandUser=root above). No separate keytab/kinit needed.
#
# Why a wrapper at all (instead of pointing AuthorizedKeysCommand at `net`):
# sshd refuses commands with arguments or quoting in the AuthorizedKeysCommand
# value; the username has to come from %u in the script.
AD_AUTHKEYS_SCRIPT = """\
#!/bin/sh
# Managed by Ansible (krg-infra synology_ssh) — DO NOT EDIT.
# AuthorizedKeysCommand for sshd: prints AD-served sshPublicKey lines for $1.
set -eu
USER="${1:-}"
[ -n "$USER" ] || exit 0
# Whitelist sAMAccountName characters; reject anything else (LDAP-injection /
# shell-meta guard — sshd already passes %u which is unescaped).
case "$USER" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
/usr/local/bin/net ads search "(sAMAccountName=$USER)" sshPublicKey 2>/dev/null \\
  | sed -n 's/^sshPublicKey: //p'
"""


def _read_existing(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


def _atomic_write(path, content, mode):
    """Atomic-write `content` to `path` with `mode` perms. Returns nothing;
    raises OSError on failure. Uses a sibling tempfile + os.replace so
    readers never see a half-written file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path),
                                     delete=False, prefix="." + os.path.basename(path) + ".",
                                     suffix=".tmp") as tf:
        tf.write(content)
        tmp = tf.name
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def _restore(path, old_content):
    """Put `old_content` back at `path`. If old_content is None, the file
    didn't exist before — remove it. Used to roll back after sshd -t fails."""
    if old_content is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        with open(path, "w") as f:
            f.write(old_content)


# File-mode policy. Helper is executable; the two sshd_config files are
# 0644 (sshd checks both are readable + not world-writable).
_FILE_MODES = {
    AD_AUTHKEYS_PATH: 0o755,
    SSHD_DROP_IN:     0o644,
    SSHD_MAIN:        0o644,
}


def do_sshd_drop_in(a):
    """Three-file transaction: drop-in + main-config Include + AD-keys helper.

    Each file is diffed; only changed files are written. After all writes
    land, run `sshd -t` once. If validation fails, ALL changed files are
    rolled back to their prior content before any restart attempt — so the
    running daemon never reads a broken config. Restart sshd via systemctl
    only if anything actually changed and validation passed.
    """
    desired_dropin = _render_drop_in(_bool(a.allow_password), _bool(a.allow_root),
                                     a.allowed_algos or "")
    desired_helper = AD_AUTHKEYS_SCRIPT
    current_main = _read_existing(SSHD_MAIN) or ""
    desired_main = _ensure_include_block(current_main)

    plan = []  # list of (path, old_content_or_None, new_content)
    for path, desired in (
        (SSHD_DROP_IN, desired_dropin),
        (AD_AUTHKEYS_PATH, desired_helper),
        (SSHD_MAIN, desired_main),
    ):
        old = _read_existing(path)
        if old != desired:
            plan.append((path, old, desired))

    if not plan:
        print("OK no-change")
        return 0

    drift_summary = {p: {"exists": old is not None,
                         "bytes_current": len(old) if old is not None else 0,
                         "bytes_desired": len(new)}
                     for p, old, new in plan}
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift_summary, sort_keys=True))
        return 0

    # Apply: write all candidates atomically. If `sshd -t` rejects, walk back
    # through the plan in reverse and restore prior contents BEFORE any restart
    # attempt — so the running daemon's view of disk is identical to before.
    # `os.replace` is the atomicity primitive across all three writes.
    try:
        for path, _old, new in plan:
            _atomic_write(path, new, _FILE_MODES[path])
        v = subprocess.run(["sshd", "-t"], capture_output=True, text=True)
        if v.returncode != 0:
            for path, old, _new in reversed(plan):
                _restore(path, old)
            print("FAIL " + json.dumps({"sshd -t": v.stderr.strip()[:400]}))
            return 1
        # Restart sshd via systemd (DSM 7.x IS systemd-based — `sshd.service`
        # is a standard OpenBSD-style unit with a synorelay drop-in for DSM's
        # service-aspect framework). The earlier `synoservicectl` invocation
        # was a guess from old DSM 6 docs; it doesn't exist on this DSM 7.3
        # build (empirical e4e-nas 2026-05-30). sshd survives a restart
        # without dropping existing sessions because per-connection children
        # are forked from the master daemon — only new connections see the
        # restarted daemon. The drop-in has already been validated with
        # `sshd -t` above, so we know the config is parseable.
        r = subprocess.run(["systemctl", "restart", "sshd"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("FAIL " + json.dumps({"systemctl restart sshd": r.stderr.strip()[:400]}))
            return 1
    except OSError as e:
        print("FAIL " + json.dumps({"error": str(e)}))
        return 1

    print("CHANGED " + json.dumps(drift_summary, sort_keys=True))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM SSH/Terminal config via synowebapi + sshd drop-in.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("terminal", help="DSM Terminal (ssh+port+telnet+sftp)")
    t.add_argument("--ssh-enable", dest="ssh_enable", required=True)
    t.add_argument("--ssh-port", dest="ssh_port", required=True)
    t.add_argument("--telnet-enable", dest="telnet_enable", required=True)
    # --sftp-enable accepted but ignored — SFTP lives on
    # SYNO.Core.FileServ.SFTP (synology_services), not SYNO.Core.Terminal.
    # Argparse continues to accept the flag so callers don't break; the
    # value is just dropped. Remove this whole line once the synology_ssh
    # role drops --sftp-enable from its task invocation.
    t.add_argument("--sftp-enable", dest="sftp_enable", default=None)
    t.add_argument("--check", action="store_true")
    t.set_defaults(func=do_terminal)

    s = sub.add_parser("sshd-drop-in", help="sshd_config.d/10-krg-hardening.conf")
    s.add_argument("--allow-password", dest="allow_password", required=True)
    s.add_argument("--allow-root", dest="allow_root", required=True)
    s.add_argument("--allowed-algos", dest="allowed_algos", default="")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_sshd_drop_in)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
