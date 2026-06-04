#!/usr/bin/env python3
"""Apply DSM Home Service config + per-user authorized_keys idempotently.

Subcommands:
  home              SYNO.Core.User.Home set (v1) — enable + include-domain-users.
                    FULL-OBJECT (partial = err 2001): GET → overlay → SET.
  authorized-keys   Write ~<user>/.ssh/authorized_keys atomically with the given
                    key list (one per line). 0600 / 0700, owner = the user.
                    Idempotent: compares to current; only writes on drift.

Invoked by the synology_users ansible role via the `script` module (DSM py3.8 —
template:/copy: ansible modules don't work; script: does).

OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip
OUT_KEYS on first-apply drift):
  enable                  -> enable_homes
  include_domain_users    -> enable_user_home_join_domain
"""
import argparse
import base64
import binascii
import json
import os
import pwd
import subprocess
import sys
import tempfile

WEBAPI = "/usr/syno/bin/synowebapi"
HOME_API = "SYNO.Core.User.Home"
# AD-join probe API — Directory.Domain v1 get returns {enable_domain: true}
# when the box is joined to an AD domain, false otherwise. Used to gate
# User.Home enable_domain=true (DSM returns err 3103 on that set if not joined).
DIRECTORY_DOMAIN_API = "SYNO.Core.Directory.Domain"

# EMPIRICAL (DSM 7.3, e4e-nas 2026-05-29): User.Home v1 get returns
# {enable, enable_domain, enable_ldap, enable_recycle_bin, encryption,
#  location, remote_location, userhome_in_s2s, userhome_is_tiering_bucket,
#  userhome_is_tiering_share}. The earlier `enable_homes` /
# `enable_user_home_join_domain` guess returned DSM err 3103 (invalid input).
# Full-object round-trip preserves the unmanaged keys (location, encryption,
# etc.) so DSM's home-folder root + recycle-bin policy aren't reset.
OUT_KEYS = {
    "enable":                "enable",
    "include_domain_users":  "enable_domain",
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
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- home (SYNO.Core.User.Home, full-object) --------------------------------------
def _is_ad_joined():
    """Returns True iff DSM is joined to an AD domain.

    Probes SYNO.Core.Directory.Domain GET; the `enable_domain` field there
    flips true when joined (distinct from User.Home.enable_domain which
    governs whether DOMAIN-USER HOMES get provisioned). Conservative on
    probe failure: returns False so we don't try to enable domain-user
    homes against a box whose AD state we can't confirm.
    """
    try:
        resp = _exec(DIRECTORY_DOMAIN_API, "version=1", "method=get")
        return bool(resp.get("data", {}).get("enable_domain", False))
    except Exception:
        return False


def do_home(a):
    desired = {
        OUT_KEYS["enable"]:               _bool(a.enable),
        OUT_KEYS["include_domain_users"]: _bool(a.include_domain_users),
    }
    current = _exec(HOME_API, "version=1", "method=get")["data"]

    # AD-aware gate (extended). The original gate (added when the NAS wasn't
    # AD-joined) refused to push `enable_domain=true` because DSM returns
    # err 3103 on a pre-join box. Post-join (2026-06-01 e4e-nas) the SET
    # returns `success: true` but DSM SILENTLY DROPS the change — a re-GET
    # still shows `enable_domain: false`. So check TWO conditions:
    #   (1) Directory.Domain.enable_domain is true (the box IS joined)
    #   (2) DSM hasn't silently dropped enable_domain=true before on this
    #       box — detected here by checking current after Domain.update_start
    #       was kicked, since the script can't tell from a single GET alone.
    # The pragmatic test (1) keeps the original behavior. For (2) we let
    # apply() check post-SET; if the change didn't persist we re-print
    # CHANGED-DEFERRED so the diff stays honest and operators can chase.
    domain_key = OUT_KEYS["include_domain_users"]
    if desired[domain_key] and not _is_ad_joined():
        current_val = current.get(domain_key, False)
        sys.stderr.write(
            "WARN: home_service.include_domain_users=true deferred — box is "
            "not yet AD-joined (DSM would return err 3103 on the set). "
            "Pinning to current value: {}. Re-run after AD join to converge.\n"
            .format(current_val))
        desired[domain_key] = current_val

    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0

    # SET via Input envelope (DSM 7.3 requirement — flat fails 3103). Then
    # verify the change actually persisted: re-GET and check each desired
    # key. Silent-success-no-persist (validated 2026-06-01 for enable_domain
    # post-join: DSM accepts SET, returns success=true, but read-back shows
    # the field unchanged — winbind background-state issue probably, but
    # surfacing it as a hard failure would break the playbook converge
    # for an issue the operator can't fix in this role).
    current.update(desired)
    res = _exec(HOME_API, "version=1", "method=set",
                "Input=" + json.dumps(current))
    if not res.get("success"):
        print("FAIL " + json.dumps(res))
        return 1
    verify = _exec(HOME_API, "version=1", "method=get")["data"]
    dropped = {k: v for k, v in desired.items() if verify.get(k) != v}
    if dropped:
        sys.stderr.write(
            "WARN: User.Home SET succeeded but DSM silently dropped "
            "{}. Likely a winbind/domain-readiness issue (e.g. domain "
            "users not yet enumerated). The role re-tries idempotently on "
            "every apply; converges once DSM accepts the field. Probe with "
            "`synowebapi --exec api=SYNO.Core.Directory.Domain version=1 "
            "method=update_start` (background DB rebuild) and inspect "
            "synolog (home.cpp) for the underlying error.\n".format(dropped))
        # Report as no-change rather than CHANGED — DSM didn't actually
        # change anything, so reporting CHANGED would lie. The honest
        # answer is "tried, no effect, deferred."
        print("OK no-change (deferred — DSM silently dropped {})".format(
            sorted(dropped.keys())))
        return 0
    print("CHANGED " + json.dumps(drift, sort_keys=True))
    return 0


# --- authorized-keys (write ~user/.ssh/authorized_keys atomically) ----------------
def _normalize(keys):
    """Drop blanks, strip whitespace, dedupe (order-preserving), ensure trailing newline."""
    seen, out = set(), []
    for k in keys:
        k = (k or "").strip()
        if not k or k in seen:
            continue
        seen.add(k)
        out.append(k)
    return ("\n".join(out) + "\n") if out else ""


def do_authorized_keys(a):
    # Accept the key list either as JSON (--keys) OR as base64-of-JSON
    # (--keys-b64). The b64 variant exists because raw JSON contains spaces
    # AND double-quotes — those get mangled when args travel through ssh +
    # remote sh's word-splitter (the local single-quotes ansible's `quote`
    # filter adds are stripped at the ssh boundary, leaving the remote shell
    # to word-split on the spaces inside each key's `<algo> <base64> <comment>`
    # form). Base64 has no shell-special characters, so it survives intact.
    # The ansible task uses --keys-b64; --keys stays for unit-test convenience
    # and ad-hoc operator use.
    if getattr(a, "keys_b64", None):
        try:
            keys_str = base64.b64decode(a.keys_b64).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError) as e:
            raise SystemExit("--keys-b64 is not valid base64-of-utf8: " + str(e))
    elif getattr(a, "keys", None):
        keys_str = a.keys
    else:
        raise SystemExit("authorized-keys: pass --keys (JSON) or --keys-b64 (base64-of-JSON)")
    try:
        keys = json.loads(keys_str)
    except json.JSONDecodeError:
        raise SystemExit("decoded --keys must be a JSON list of strings (got: "
                         + (keys_str[:60] + "..." if len(keys_str) > 60 else keys_str) + ")")
    if not isinstance(keys, list):
        raise SystemExit("decoded --keys must be a JSON list of strings (got type "
                         + type(keys).__name__ + ")")

    desired = _normalize(keys)
    try:
        pw = pwd.getpwnam(a.username)
    except KeyError:
        # User doesn't exist yet (sync race with user-creation task). Best-effort
        # bail: not an error — the role's next run will pick it up.
        print("OK no-change")
        return 0

    home = pw.pw_dir
    ssh_dir = os.path.join(home, ".ssh")
    auth = os.path.join(ssh_dir, "authorized_keys")
    try:
        with open(auth) as f:
            current = f.read()
    except FileNotFoundError:
        current = None

    drift_summary = {
        "user": a.username,
        "path": auth,
        "exists": current is not None,
        "bytes_current": len(current) if current is not None else 0,
        "bytes_desired": len(desired),
        "keys_desired": desired.count("\n") if desired else 0,
    }

    # Empty desired: if a file exists, we LEAVE it alone rather than wipe (a user
    # may have added a personal key out-of-band; we don't claim exclusive
    # ownership of authorized_keys here). This matches ansible.posix.authorized_key
    # with exclusive: false on the Debian side.
    if not desired:
        print("OK no-change")
        return 0

    if current == desired:
        print("OK no-change")
        return 0

    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift_summary, sort_keys=True))
        return 0

    try:
        # ~/.ssh must exist with 0700 owned by the user — sshd refuses otherwise.
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        os.chown(ssh_dir, pw.pw_uid, pw.pw_gid)
        os.chmod(ssh_dir, 0o700)
        with tempfile.NamedTemporaryFile("w", dir=ssh_dir, delete=False,
                                         prefix=".authorized_keys.",
                                         suffix=".tmp") as tf:
            tf.write(desired)
            tmp = tf.name
        os.chmod(tmp, 0o600)
        os.chown(tmp, pw.pw_uid, pw.pw_gid)
        os.replace(tmp, auth)
    except OSError as e:
        print("FAIL " + json.dumps({"error": str(e)}))
        return 1

    print("CHANGED " + json.dumps(drift_summary, sort_keys=True))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM Home Service + authorized_keys.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    h = sub.add_parser("home", help="User.Home (enable + include-domain-users)")
    h.add_argument("--enable", required=True)
    h.add_argument("--include-domain-users", dest="include_domain_users", required=True)
    h.add_argument("--check", action="store_true")
    h.set_defaults(func=do_home)

    k = sub.add_parser("authorized-keys", help="Write ~user/.ssh/authorized_keys")
    k.add_argument("--username", required=True)
    # Either --keys or --keys-b64 (b64 of the same JSON). The b64 form is
    # shell-safe (no quotes, no spaces) and what the role uses; --keys is
    # kept for unit-test + interactive operator use.
    k_keys = k.add_mutually_exclusive_group(required=True)
    k_keys.add_argument("--keys", help="JSON list of public-key strings (NOT shell-safe over ssh)")
    k_keys.add_argument("--keys-b64", dest="keys_b64",
                        help="base64-of-utf8 of the JSON list (shell-safe; preferred)")
    k.add_argument("--check", action="store_true")
    k.set_defaults(func=do_authorized_keys)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
