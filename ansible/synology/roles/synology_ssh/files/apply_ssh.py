#!/usr/bin/env python3
"""Apply DSM Terminal config + sshd_config hardening drop-in idempotently.

Subcommands:
  terminal      SYNO.Core.Terminal set (v1) — ssh.enable + ssh.port + telnet.enable +
                sftp.enable. FULL-OBJECT (partial = err 2001): GET → overlay → SET.
  sshd-drop-in  Write /etc/ssh/sshd_config.d/10-krg-hardening.conf
                (PasswordAuthentication no / PermitRootLogin no / pubkey algos).
                Writes the candidate atomically, then validates with `sshd -t`
                and rolls back if validation fails (BEFORE any restart, so the
                running daemon never reads a broken config). Restarts sshd via
                `systemctl restart sshd` only on change — DSM 7.x is
                systemd-based and `sshd.service` is a standard OpenBSD-style
                unit. DSM has no UI toggle for these settings, so they must
                live in sshd_config — and `template:`/`copy:` ansible modules
                don't work on DSM's python 3.8 (below ansible's module floor),
                so the script ships the file itself.

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


# --- sshd-drop-in (write /etc/ssh/sshd_config.d/10-krg-hardening.conf) -------------
SSHD_TEMPLATE = """\
# Managed by Ansible (krg-infra synology_ssh) — DO NOT EDIT.
# Mirrors ansible/roles/ssh_hardening/templates/10-krg-hardening.conf.j2 and
# nix/profiles/base.nix services.openssh.settings. DSM's UI has no toggle for
# these settings, so they live here. A DSM major update can REVERT this file —
# re-apply synology_base after upgrades.

PasswordAuthentication {pw}
PermitRootLogin {root}
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
{algos}"""


def _render_drop_in(allow_password, allow_root, allowed_algos):
    algos = ""
    if allowed_algos:
        algos = ("PubkeyAcceptedAlgorithms " + allowed_algos + "\n"
                 "HostKeyAlgorithms " + allowed_algos + "\n")
    return SSHD_TEMPLATE.format(
        pw="yes" if allow_password else "no",
        root="yes" if allow_root else "no",
        algos=algos,
    )


def _read_existing(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


def do_sshd_drop_in(a):
    desired = _render_drop_in(_bool(a.allow_password), _bool(a.allow_root),
                              a.allowed_algos or "")
    current = _read_existing(SSHD_DROP_IN)
    if current == desired:
        print("OK no-change")
        return 0
    drift_summary = {
        "path": SSHD_DROP_IN,
        "exists": current is not None,
        "bytes_current": len(current) if current is not None else 0,
        "bytes_desired": len(desired),
    }
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift_summary, sort_keys=True))
        return 0

    # Write the candidate via a tempfile + os.replace (atomic), THEN validate
    # with `sshd -t`. If validation fails, restore the previous drop-in
    # content (or remove the file if there was none) BEFORE restarting sshd,
    # so the running daemon never reads a broken config. Net effect = safe;
    # a sibling "validate-before-replace" approach was considered but reading
    # sshd's full config-load path from a tempfile is brittle (Include
    # directives + ordering), so we use the replace-then-validate-with-rollback
    # variant. The comment near the docstring used to claim the other order —
    # corrected here per reviewer 4577021512.
    try:
        os.makedirs(os.path.dirname(SSHD_DROP_IN), exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(SSHD_DROP_IN),
                                         delete=False, prefix=".10-krg-hardening.",
                                         suffix=".tmp") as tf:
            tf.write(desired)
            tmp = tf.name
        os.chmod(tmp, 0o644)
        # Move the temp into place; old drop-in (if any) is overwritten atomically
        # by os.replace. sshd -t after replacement, then restart; if validation
        # fails AFTER replacement we put the old content back.
        old_content = current
        os.replace(tmp, SSHD_DROP_IN)
        v = subprocess.run(["sshd", "-t"], capture_output=True, text=True)
        if v.returncode != 0:
            if old_content is None:
                os.remove(SSHD_DROP_IN)
            else:
                with open(SSHD_DROP_IN, "w") as f:
                    f.write(old_content)
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
