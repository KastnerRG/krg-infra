#!/usr/bin/env python3
"""Apply DSM Security Advisor schedule idempotently via synowebapi.

Subcommand:
  main   SYNO.Core.SecurityScan.Conf set (v1) — schedule enable + weekly time.
         FULL-OBJECT pattern (partial = err 2001): GET → overlay managed keys
         → SET, only on drift. Strips read-only synthetic keys
         (`success`, `scheduleTaskId`) before SET so the round-trip is valid.

Invoked by the synology_security_advisor ansible role via the `script` module
(DSM Python 3.8 — same constraint as the rest of the synology_* helpers).
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>; the role
keys changed_when/failed_when off stdout.

Field mapping (DSM 7.3, EMPIRICALLY CONFIRMED 2026-05-29 from
`/usr/syno/synoman/webapi/SYNO.Core.SecurityScan.lib` + a live GET):
  enable                  -> enableSchedule    (bool)
  schedule.day (Sun..Sat) -> weekday "0".."6"  (Unix-cron convention)
  schedule.hour           -> hour              (int)
  schedule.minute         -> minute            (int)

NOT managed here (different DSM surfaces; spec values are accepted on the CLI
to keep the role contract stable, but applied = false until the follow-ups
land — see role README):
  scan_categories         -> SYNO.Core.SecurityScan.Conf.group_set
                             (param shape needs probing on a configured box;
                             `defaultGroup` from current live state is preserved
                             by the full-object round-trip)
  notify_email_on_finding -> SYNO.Core.Notification.Event
                             (the email channel is owned by synology_notifications;
                             SA hooks into that channel — no SA-side toggle)
"""

import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SA_CONF_API = "SYNO.Core.SecurityScan.Conf"

# Spec-field -> DSM-field. EMPIRICAL — flipped on first-apply discovery 2026-05-29
# (original `.Main`/`enable`/`schedule_day` guess from `.lib` filename was wrong;
# real namespace is `.Conf` and real keys are `enableSchedule`/`weekday`/etc.).
OUT_KEYS = {
    "enable": "enableSchedule",
    "day": "weekday",
    "hour": "hour",
    "minute": "minute",
}

# Sun..Sat -> "0".."6" (Unix-cron convention; DSM stores weekday as a string-of-digit).
DAY_MAP = {"Sun": "0", "Mon": "1", "Tue": "2", "Wed": "3", "Thu": "4", "Fri": "5", "Sat": "6"}

# `Conf get` returns these keys inside `data` but `Conf set` rejects them —
# strip before SET. Only `success` qualifies; `scheduleTaskId` LOOKS internal
# but the UI's SET payload (captured 2026-06-01 from HAR) DOES include it,
# and omitting it gets a 114 back. So we round-trip it.
#   * success         — synthetic OK marker DSM stuffs into data dicts
READ_ONLY_KEYS = {"success"}

# DSM error code 102 == "API does not exist" (rare for Conf — handled
# defensively in case a stripped/older DSM image is in play).
ERR_API_NOT_EXIST = 102


def _exec(api, *params):
    """Run synowebapi; preamble on stderr, JSON on stdout."""
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


def _exec_get(api):
    """GET; returns (data_dict, None) on success or (None, err_code) on
    DSM-level failure. Raises only on protocol violations (no JSON / success
    with no data — neither is a normal state).
    """
    resp = _exec(api, "version=1", "method=get")
    if not resp.get("success", False):
        return None, (resp.get("error") or {}).get("code")
    if "data" not in resp:
        raise RuntimeError(
            "DSM API {} GET returned success but no `data` key: {}".format(api, json.dumps(resp))
        )
    return resp["data"], None


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def _coerce_like(target, current_val):
    """Coerce current_val to type of target so type-only mismatches don't
    false-positive drift (M5 fix from reviewer 4577021512). DSM JSON sometimes
    returns ints as strings; this normalizes for the diff comparison."""
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


def do_main(a):
    if a.day not in DAY_MAP:
        raise SystemExit(
            "--day must be one of: " + ", ".join(DAY_MAP) + " (got: " + str(a.day) + ")"
        )
    # --categories and --notify-email are accepted but NOT applied (different
    # DSM surfaces; see module docstring). Validate them so a typo still fails
    # loudly, but don't push them on the wire here.
    if a.categories:
        try:
            cats = json.loads(a.categories)
            if not isinstance(cats, list):
                raise SystemExit(
                    "--categories must be a JSON list (got type " + type(cats).__name__ + ")"
                )
        except json.JSONDecodeError as e:
            raise SystemExit("--categories must be valid JSON: " + str(e))

    desired = {
        OUT_KEYS["enable"]: _bool(a.enable),
        OUT_KEYS["day"]: DAY_MAP[a.day],
        OUT_KEYS["hour"]: int(a.hour),
        OUT_KEYS["minute"]: int(a.minute),
    }

    current, err = _exec_get(SA_CONF_API)
    if err is not None:
        note = (
            "API not present on this DSM model — Security Advisor "
            "scheduling cannot be managed via webapi here."
            if err == ERR_API_NOT_EXIST
            else "see DSM error code table"
        )
        print(
            "FAIL "
            + json.dumps(
                {
                    "error": "GET failed",
                    "api": SA_CONF_API,
                    "code": err,
                    "note": note,
                }
            )
        )
        return 1

    set_payload = {k: v for k, v in current.items() if k not in READ_ONLY_KEYS}

    drift = {
        k: {"current": set_payload.get(k), "desired": v}
        for k, v in desired.items()
        if _coerce_like(v, set_payload.get(k)) != v
    }

    def apply():
        # SecurityScan.Conf SET requires its params wrapped in an `Input`
        # envelope (validated 2026-06-01 from a HAR of the DSM UI — flat
        # params return err 114 "Bad parameters" on this DSM, even when the
        # payload is the unmodified GET response). All other DSM SETs in
        # this repo take flat params; only this one needs the envelope.
        set_payload.update(desired)
        return _exec(SA_CONF_API, "version=1", "method=set", "Input=" + json.dumps(set_payload))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM Security Advisor schedule via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("main", help="SecurityScan.Conf (enableSchedule + weekday + hour + minute)")
    s.add_argument("--enable", required=True)
    s.add_argument("--day", required=True, help="Sun|Mon|Tue|Wed|Thu|Fri|Sat")
    s.add_argument("--hour", required=True, type=int)
    s.add_argument("--minute", required=True, type=int)
    # Accepted-but-deferred (see docstring); kept on the CLI so the role
    # contract stays stable while the per-surface impls are tracked.
    s.add_argument(
        "--categories",
        required=True,
        help="JSON list of strings (accepted, NOT applied — needs group_set probe)",
    )
    s.add_argument(
        "--notify-email",
        dest="notify_email",
        required=True,
        help="bool (accepted, NOT applied — owned by synology_notifications)",
    )
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_main)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
