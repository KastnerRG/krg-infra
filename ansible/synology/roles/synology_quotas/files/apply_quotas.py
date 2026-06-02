#!/usr/bin/env python3
"""Apply DSM per-share / per-user quotas idempotently via the synoquota CLI.

Two subcommands:
  share  Per-share quota (cap, hard/soft).
  user   Per-user-per-volume quota (cap, hard/soft).

Run by synology_quotas role via `script:` (DSM py3.8). Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <msg>.

`size_gib: 0` = remove the quota. `hard: true` = block writes when full; `false` =
soft / warn only (notification goes through synology_notifications channel).

Idempotency: parse `synoquota --get` / `--get-share` to find the current value,
diff, only call `--set*` if it changed. The exact `synoquota` subcommand names
are best-known (validated on the 2026-05-28 live capture which showed quotas
existed); first-apply may surface different flag names — flip the CMDS table.

SAFETY: if the parser can't extract the current value, the script BAILS (treats
parse-failure as drift but errors instead of guessing). Better a noisy FAIL than
applying spec-drift over a misread current state.
"""
import argparse
import json
import re
import subprocess
import sys

SYNOQUOTA = "/usr/syno/bin/synoquota"

# Subcommand flag names — best-known from the live `synoquota --help` (the
# 2026-05-28 capture saw `--user-list` and the user-quota path; verify others).
CMDS = {
    "share_get": ["--get-share"],
    "share_set": ["--set-share"],
    "share_clear": ["--clear-share"],
    "user_get": ["--get"],
    "user_set": ["--set"],
    "user_clear": ["--clear"],
}

GIB = 1 << 30


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


# Parse `synoquota --get <args>` style output. Expected free-form like:
#   "Quota: 500.0 GB (Hard)"
# or
#   "Quota: 500 GB"
# or
#   "No quota set"
QUOTA_RE = re.compile(r"Quota[:\s]*([\d.]+)\s*(GB|GiB|MB|MiB|TB|TiB)?\s*(\(Hard\)|\(Soft\))?",
                      re.IGNORECASE)


def _parse_current(text):
    """Return (size_gib_int_or_None, hard_bool_or_None). None size = no quota set.

    Unit handling (M3 fix from reviewer 4577021512):
      The setter writes bytes computed as `desired * (1<<30)` — i.e. desired is
      ALWAYS interpreted as GiB (binary). The reader must convert DSM's display
      units to the same GiB scale before comparing, or every run sees drift and
      re-applies forever (500 GiB == 537 GB; 500 != 537 → CHANGED again).

      GB / MB / TB  = decimal (10^9 / 10^6 / 10^12 bytes)
      GiB / MiB / TiB = binary (2^30 / 2^20 / 2^40 bytes)

      We normalize everything to GiB. Implicit unit (no unit suffix) is
      ambiguous; DSM 7.x typically prints "GB" for the decimal form, so we
      default to GB → GiB conversion. If the first apply shows drift purely
      because of a unit-default mismatch, flip DEFAULT_UNIT to "gib".
    """
    if not text or re.search(r"no quota", text, re.IGNORECASE):
        return (None, None)
    m = QUOTA_RE.search(text)
    if not m:
        return ("UNPARSEABLE", None)
    size, raw_unit, hard_tag = m.group(1), (m.group(2) or "").lower(), m.group(3)
    val = float(size)

    DEFAULT_UNIT = "gb"   # treat bare numbers as decimal; flip to "gib" if DSM proves otherwise
    unit = raw_unit or DEFAULT_UNIT

    if unit in ("gb", "mb", "tb"):
        # Decimal -> bytes -> GiB.
        decimal_bytes = {"mb": 10 ** 6, "gb": 10 ** 9, "tb": 10 ** 12}[unit]
        val_gib = (val * decimal_bytes) / (1 << 30)
    else:
        # Binary -> GiB directly.
        binary_scale = {"mib": 1 / 1024.0, "gib": 1.0, "tib": 1024.0}[unit]
        val_gib = val * binary_scale

    val_gib_int = int(round(val_gib))
    hard = (hard_tag is not None and "hard" in hard_tag.lower())
    return (val_gib_int, hard)


def _result(drift, check, apply_fn):
    if not drift:
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    res_rc = apply_fn()
    if res_rc == 0:
        print("CHANGED " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    print("FAIL " + json.dumps({"rc": res_rc}))
    return 1


# --- share quota ------------------------------------------------------------
def do_share(a):
    desired_size = int(a.size_gib)
    desired_hard = _bool(a.hard)

    r = _run([SYNOQUOTA] + CMDS["share_get"] + [a.share])
    cur_size, cur_hard = _parse_current(r.stdout or r.stderr)
    if cur_size == "UNPARSEABLE":
        print("FAIL " + json.dumps({"error": "could not parse current quota",
                                    "share": a.share,
                                    "stdout": (r.stdout or "")[:300]}))
        return 1

    drift = {}
    if desired_size == 0 and cur_size is not None:
        drift = {"action": "clear", "current_gib": cur_size}
    elif desired_size != 0 and (cur_size != desired_size or cur_hard != desired_hard):
        drift = {"current_gib": cur_size, "current_hard": cur_hard,
                 "desired_gib": desired_size, "desired_hard": desired_hard}

    def apply():
        if desired_size == 0:
            return _run([SYNOQUOTA] + CMDS["share_clear"] + [a.share]).returncode
        flag = "hard" if desired_hard else "soft"
        cmd = [SYNOQUOTA] + CMDS["share_set"] + [
            a.share, "--size", str(desired_size * GIB), "--type", flag,
        ]
        return _run(cmd).returncode

    return _result(drift, a.check, apply)


# --- user quota -------------------------------------------------------------
def do_user(a):
    desired_size = int(a.size_gib)
    desired_hard = _bool(a.hard)

    r = _run([SYNOQUOTA] + CMDS["user_get"] + ["--user", a.user, "--volume", a.volume])
    cur_size, cur_hard = _parse_current(r.stdout or r.stderr)
    if cur_size == "UNPARSEABLE":
        print("FAIL " + json.dumps({"error": "could not parse current quota",
                                    "user": a.user, "volume": a.volume,
                                    "stdout": (r.stdout or "")[:300]}))
        return 1

    drift = {}
    if desired_size == 0 and cur_size is not None:
        drift = {"action": "clear", "current_gib": cur_size}
    elif desired_size != 0 and (cur_size != desired_size or cur_hard != desired_hard):
        drift = {"current_gib": cur_size, "current_hard": cur_hard,
                 "desired_gib": desired_size, "desired_hard": desired_hard}

    def apply():
        if desired_size == 0:
            return _run([SYNOQUOTA] + CMDS["user_clear"] + [
                "--user", a.user, "--volume", a.volume]).returncode
        flag = "hard" if desired_hard else "soft"
        cmd = [SYNOQUOTA] + CMDS["user_set"] + [
            "--user", a.user, "--volume", a.volume,
            "--size", str(desired_size * GIB), "--type", flag,
        ]
        return _run(cmd).returncode

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM quotas via synoquota.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("share", help="Per-share quota")
    s.add_argument("--share", required=True)
    s.add_argument("--size-gib", dest="size_gib", required=True)
    s.add_argument("--hard", required=True)
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_share)

    u = sub.add_parser("user", help="Per-user-per-volume quota")
    u.add_argument("--user", required=True)
    u.add_argument("--volume", required=True)
    u.add_argument("--size-gib", dest="size_gib", required=True)
    u.add_argument("--hard", required=True)
    u.add_argument("--check", action="store_true")
    u.set_defaults(func=do_user)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
