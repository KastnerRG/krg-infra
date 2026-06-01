#!/usr/bin/env python3
"""Apply DSM auto-update policy idempotently via synowebapi.

One subcommand:

  setting   SYNO.Core.Upgrade.Setting set (v2) — auto-update enable + policy +
            weekly schedule. FULL-OBJECT pattern (partial = err 2001): GET →
            overlay managed keys → SET, only on drift. Preserves unmanaged
            DSM-internal keys (`smart_nano_enabled`, `upgrade_type` legacy).

Invoked by the synology_dsm_updates ansible role via the `script` module (DSM
Python 3.8). OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3, EMPIRICALLY CONFIRMED 2026-05-29 from a live
`Upgrade.Setting v2 get` capture + the `SYNO.Core.Upgrade.lib` method list):
  enable                  -> autoupdate_enable    (bool)
  policy                  -> autoupdate_type      ("hotfix"|"hotfix-security"|"smart"|...)
  schedule.day (Sun..Sat) -> schedule.week_day    "0".."6"  (NESTED)
  schedule.hour           -> schedule.hour        (NESTED)
  schedule.minute         -> schedule.minute      (NESTED)

NOT managed here (different DSM surfaces — accepted on CLI for spec stability,
but no-op on the wire; tracked as follow-ups in the role README):
  notify_email_on_install -> SYNO.Core.Notification.Event (owned by
                             synology_notifications; DSM routes all email
                             through the central Notification channel, not
                             per-event)
  update_channel          -> NOT A DSM SURFACE on this model. `Upgrade.Server`
                             exposes only `check` (no get/set). Channel is
                             effectively immutable from the WebAPI here —
                             the spec field is preserved for forward-compat
                             but does nothing.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
UPD_SETTING_API = "SYNO.Core.Upgrade.Setting"
# v2 is the richest GET shape on DSM 7.3 (includes the nested `schedule` dict
# AND `autoupdate_enable`/`autoupdate_type`; v1 only returns `auto_download`+`upgrade_type`).
UPD_SETTING_VERSION = 2

# Spec-field -> DSM-field. EMPIRICAL (replaces the earlier best-known guess
# that used `auto_update_type`/`enable_auto_update`/`upgrade_day` — none of
# which exist on this DSM).
OUT_KEYS = {
    "enable":  "autoupdate_enable",
    "policy":  "autoupdate_type",
    # `day`/`hour`/`minute` live UNDER the nested `schedule` dict, not at top
    # level — see do_setting for the nested merge.
}
SCHED_KEYS = {
    "day":    "week_day",
    "hour":   "hour",
    "minute": "minute",
}

# Sun..Sat -> "0".."6" (Unix-cron convention; DSM stores week_day as a string-of-digit).
DAY_MAP = {"Sun": "0", "Mon": "1", "Tue": "2", "Wed": "3",
           "Thu": "4", "Fri": "5", "Sat": "6"}

ERR_API_NOT_EXIST = 102


def _exec(api, version, method, *params):
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + api, "version=" + str(version),
         "method=" + method, *params],
        capture_output=True, text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _exec_get(api, version):
    """GET; returns (data_dict, None) on success or (None, err_code) on DSM failure."""
    resp = _exec(api, version, "get")
    if not resp.get("success", False):
        return None, (resp.get("error") or {}).get("code")
    if "data" not in resp:
        raise RuntimeError("DSM API {} GET returned success but no `data` key: {}".format(
            api, json.dumps(resp)))
    return resp["data"], None


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _coerce_like(target, current_val):
    """Coerce current_val to type of target so type-only diffs don't false-positive."""
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
    """dict -> synowebapi key=value tokens (bool->true/false, null skipped, list/dict->JSON)."""
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


def do_setting(a):
    if a.day not in DAY_MAP:
        raise SystemExit("--day must be one of: " + ", ".join(DAY_MAP) +
                         " (got: " + str(a.day) + ")")

    # `--notify-email` and `--update-channel` are accepted but NOT applied
    # (different / nonexistent DSM surfaces — see docstring). Kept on the CLI
    # so the role contract stays stable.
    _ = a.notify_email  # spec value; ignored on wire
    _ = a.update_channel  # spec value; ignored on wire (no Upgrade.Server set)

    desired_top = {
        OUT_KEYS["enable"]: _bool(a.auto_install),
        OUT_KEYS["policy"]: a.policy,
    }
    desired_sched = {
        SCHED_KEYS["day"]:    DAY_MAP[a.day],
        SCHED_KEYS["hour"]:   int(a.hour),
        SCHED_KEYS["minute"]: int(a.minute),
    }

    current, err = _exec_get(UPD_SETTING_API, UPD_SETTING_VERSION)
    if err is not None:
        note = ("API not present on this DSM model — update policy cannot be "
                "managed via webapi here." if err == ERR_API_NOT_EXIST
                else "see DSM error code table")
        print("FAIL " + json.dumps({
            "error": "GET failed", "api": UPD_SETTING_API,
            "version": UPD_SETTING_VERSION, "code": err, "note": note,
        }))
        return 1

    cur_sched = current.get("schedule") or {}

    # Drift = any managed top-level OR managed nested-schedule field that's wrong.
    drift = {}
    for k, v in desired_top.items():
        if _coerce_like(v, current.get(k)) != v:
            drift[k] = {"current": current.get(k), "desired": v}
    for k, v in desired_sched.items():
        if _coerce_like(v, cur_sched.get(k)) != v:
            drift["schedule." + k] = {"current": cur_sched.get(k), "desired": v}

    def apply():
        # Full-object overlay: keep unmanaged keys (smart_nano_enabled,
        # upgrade_type, etc.), merge nested schedule.
        merged = dict(current)
        merged.update(desired_top)
        merged["schedule"] = dict(cur_sched, **desired_sched)
        return _exec(UPD_SETTING_API, UPD_SETTING_VERSION, "set", *_args_from(merged))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM auto-update policy via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setting", help="Upgrade.Setting v2 (enable + policy + nested schedule)")
    s.add_argument("--policy", required=True)
    s.add_argument("--auto-install", dest="auto_install", required=True)
    s.add_argument("--day", required=True, help="Sun|Mon|Tue|Wed|Thu|Fri|Sat")
    s.add_argument("--hour", required=True)
    s.add_argument("--minute", required=True)
    # Accepted-but-deferred (see docstring); kept on the CLI so the role
    # contract stays stable while follow-ups land.
    s.add_argument("--notify-email", dest="notify_email", required=True,
                   help="bool (accepted, NOT applied — owned by synology_notifications)")
    s.add_argument("--update-channel", dest="update_channel", default="stable",
                   help="accepted, NOT applied — Upgrade.Server has no set on this DSM")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_setting)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
