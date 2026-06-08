#!/usr/bin/env python3
"""Apply DSM Snapshot Replication schedules per share idempotently via synowebapi.

One subcommand:
  share   SYNO.Core.Share.Snapshot set (v1) — per-share enable + retention.
          FULL-OBJECT (partial = err 2001): GET → overlay → SET on drift.

Run by synology_snapshot_replication role via `script:` (DSM py3.8).
OK / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip
OUT_KEYS on first-apply drift):
  enabled  -> enable_snapshot         (bool)
  hourly   -> keep_hourly             (int — retention count)
  daily    -> keep_daily              (int)
  weekly   -> keep_weekly             (int)
  monthly  -> keep_monthly            (int)
"""

import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SNAP_API = "SYNO.Core.Share.Snapshot"

OUT_KEYS = {
    "enabled": "enable_snapshot",
    "hourly": "keep_hourly",
    "daily": "keep_daily",
    "weekly": "keep_weekly",
    "monthly": "keep_monthly",
}


def _exec(api, *params):
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + api, *params],
        capture_output=True,
        text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _coerce_like(target, current_val):
    """Coerce current_val to the type of target for diff comparison (M5 fix).

    DSM JSON sometimes returns ints/bools as strings; this normalizes so a
    type-only mismatch doesn't false-positive drift. See reviewer 4577021512.
    """
    if current_val is None or current_val == target:
        return current_val
    if isinstance(target, bool) and not isinstance(current_val, bool):
        if isinstance(current_val, str):
            return current_val.strip().lower() in ("1", "true", "yes", "on")
        if isinstance(current_val, (int, float)):
            return bool(current_val)
    if isinstance(target, int) and not isinstance(target, bool):
        if isinstance(current_val, str):
            try:
                return int(current_val)
            except ValueError:
                pass
        if isinstance(current_val, float):
            return int(current_val)
    if isinstance(target, str) and not isinstance(current_val, str):
        return str(current_val)
    return current_val


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


def do_share(a):
    desired = {
        OUT_KEYS["enabled"]: _bool(a.enabled),
        OUT_KEYS["hourly"]: int(a.hourly),
        OUT_KEYS["daily"]: int(a.daily),
        OUT_KEYS["weekly"]: int(a.weekly),
        OUT_KEYS["monthly"]: int(a.monthly),
    }
    current = _exec(SNAP_API, "version=1", "method=get", "name=" + a.share)["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if _coerce_like(v, current.get(k)) != v
    }

    def apply():
        current.update(desired)
        return _exec(SNAP_API, "version=1", "method=set", "name=" + a.share, *_args_from(current))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply per-share DSM Snapshot Replication schedules.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("share", help="Per-share schedule + retention")
    s.add_argument("--share", required=True)
    s.add_argument("--enabled", required=True)
    s.add_argument("--hourly", required=True)
    s.add_argument("--daily", required=True)
    s.add_argument("--weekly", required=True)
    s.add_argument("--monthly", required=True)
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_share)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
