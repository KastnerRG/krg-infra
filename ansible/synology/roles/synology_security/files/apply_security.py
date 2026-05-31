#!/usr/bin/env python3
"""Apply DSM security perimeter (firewall + auto-block) idempotently via synowebapi.
Subcommands:
  firewall     — SYNO.Core.Security.Firewall set (enable, profile_name) — full-object.
  fw-conf      — SYNO.Core.Security.Firewall.Conf set (port_check) — full-object.
  autoblock    — SYNO.Core.Security.AutoBlock set (enable, attempts, within_mins,
                 expire_day) — full-object.
  geoip        — SYNO.Core.Security.Firewall.Geoip set (enable + country allowlist)
                 — full-object. Field names below are BEST GUESSES based on the
                 DSM 7.x API naming pattern (`enable_*`); first dry-run output
                 will surface the actual shape — adjust the dict keys if the
                 live response disagrees.

Per-rule firewall config (Firewall.Profile + Firewall.Rules load/save_start) and
AutoBlock allow/deny lists are NOT yet covered — the capture errored on them (wrong
param shape); add subcommands once the param shape is empirically confirmed.

Read-only diagnostics (no SET; safe to run any time):
  probe-profile — read Firewall.Profile active profile, report rule count.
  probe-geoip   — read Firewall.Geoip, report current field shape so the apply
                  function can be tuned to whatever DSM actually returns.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"


def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params],
                         capture_output=True, text=True)
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


def apply_full_object(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_firewall(a):
    desired = {}
    if a.enable is not None:
        desired["enable_firewall"] = _bool(a.enable)
    if a.profile is not None:
        desired["profile_name"] = a.profile
    return apply_full_object("SYNO.Core.Security.Firewall", 1, desired, a.check)


def do_fw_conf(a):
    desired = {}
    if a.port_check is not None:
        desired["enable_port_check"] = _bool(a.port_check)
    return apply_full_object("SYNO.Core.Security.Firewall.Conf", 1, desired, a.check)


def do_autoblock(a):
    desired = {}
    if a.enable is not None:
        desired["enable"] = _bool(a.enable)
    if a.attempts is not None:
        desired["attempts"] = int(a.attempts)
    if a.within_mins is not None:
        desired["within_mins"] = int(a.within_mins)
    if a.expire_day is not None:
        desired["expire_day"] = int(a.expire_day)
    return apply_full_object("SYNO.Core.Security.AutoBlock", 1, desired, a.check)


# --- Firewall.Geoip — country allowlist enforcement at the firewall layer -----
# DSM ships a per-country block/allow firewall feature; the API surface is
# SYNO.Core.Security.Firewall.Geoip (get/list/set per the security.lib).
# Field names below are BEST GUESSES based on the established DSM 7.x naming
# pattern (`enable_<feature>`, `*_list`). The 2026-05-28 pre-reset capture
# errored 114 on the GET — likely "no such API on this version" or "wrong
# version param" — so the first live probe is the authoritative source for
# the real shape. apply_full_object will surface the actual current values
# on first run; if our desired keys don't match (e.g. DSM returns
# `country_code_list` but we send `country_list`), the SET will FAIL loudly
# instead of silently misconfiguring — which on a country gate is critical
# (a wrong field could end up blocking ALL traffic rather than just non-US).
#
# Field-name candidates worth checking once the probe runs:
#   enable        : enable_geoip / enable / enabled
#   policy        : policy / mode / direction  (values: allow/deny/0/1)
#   countries     : country_list / country_code_list / countries / geoip_list
GEOIP_API = "SYNO.Core.Security.Firewall.Geoip"


def do_geoip(a):
    desired = {}
    if a.enable is not None:
        desired["enable_geoip"] = _bool(a.enable)
    if a.policy is not None:
        # `allow` = whitelist mode (allow only listed countries; block rest)
        # `deny`  = blacklist mode (block listed countries; allow rest)
        # For "US is the floor" we want `allow` + countries=[US].
        desired["policy"] = a.policy
    if a.countries is not None:
        # Comma-separated ISO 3166-1 alpha-2 codes from the spec → list.
        # DSM may take a JSON list or a comma-separated string; the
        # _args_from helper JSON-encodes lists already, so a list value
        # is the safer bet.
        codes = [c.strip().upper() for c in a.countries.split(",") if c.strip()]
        desired["country_list"] = codes
    return apply_full_object(GEOIP_API, 1, desired, a.check)


def do_probe_geoip(a):
    """Read-only: dump the current Firewall.Geoip object so the operator can
    confirm the actual field names against the BEST GUESS above. Prints one
    of:
      GEOIP-OK <json>         — got a usable response; json shows the real shape
      GEOIP-UNKNOWN <reason>  — API call failed; do_geoip will likely also fail
    """
    try:
        res = _exec(GEOIP_API, "version=1", "method=get")
    except RuntimeError as e:
        print("GEOIP-UNKNOWN " + json.dumps({"error": str(e)[:200]}))
        return 0
    if not res.get("success"):
        print("GEOIP-UNKNOWN " + json.dumps(res)[:200])
        return 0
    data = res.get("data", {})
    print("GEOIP-OK " + json.dumps({"keys": sorted(data.keys()), "data": data}))
    return 0


# --- Anti-lockout probe (H2) ---------------------------------------------------
# Enabling SYNO.Core.Security.Firewall on a profile with NO rules is a
# default-deny posture — DSM blocks all inbound, including the SSH session
# Ansible is running over. Probe the active profile's rule list FIRST and
# print one of:
#   PROFILE-EMPTY              — would lock us out; role asserts and halts
#   PROFILE-HAS-RULES count=N  — rules present; safe to proceed
#   PROFILE-UNKNOWN <reason>   — couldn't determine; role asserts and halts
# Best-known API: SYNO.Core.Security.Firewall.Profile method=get name=<n>
# returns rules under data.rules. First apply will surface the actual shape;
# flip RULE_KEYS if needed.
RULE_KEYS = ("rules", "rule_list", "fw_rules")


def do_probe_profile(a):
    try:
        res = _exec("SYNO.Core.Security.Firewall.Profile", "version=1",
                    "method=get", "name=" + a.profile)
    except RuntimeError as e:
        print("PROFILE-UNKNOWN " + json.dumps({"error": str(e)[:200]}))
        return 0
    data = res.get("data", {}) if res.get("success") else {}
    if not data:
        print("PROFILE-UNKNOWN " + json.dumps({"raw": res})[:200])
        return 0
    for k in RULE_KEYS:
        rules = data.get(k)
        if isinstance(rules, list):
            if not rules:
                print("PROFILE-EMPTY")
            else:
                print("PROFILE-HAS-RULES count=" + str(len(rules)))
            return 0
    # API shape we don't recognize. Treat as UNKNOWN so the role refuses to
    # blindly enable the firewall.
    print("PROFILE-UNKNOWN " + json.dumps({"keys": sorted(data.keys())}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    fw = sub.add_parser("firewall")
    fw.add_argument("--enable")
    fw.add_argument("--profile")
    fw.add_argument("--check", action="store_true")
    fw.set_defaults(func=do_firewall)

    c = sub.add_parser("fw-conf")
    c.add_argument("--port-check", dest="port_check")
    c.add_argument("--check", action="store_true")
    c.set_defaults(func=do_fw_conf)

    ab = sub.add_parser("autoblock")
    ab.add_argument("--enable")
    ab.add_argument("--attempts")
    ab.add_argument("--within-mins", dest="within_mins")
    ab.add_argument("--expire-day", dest="expire_day")
    ab.add_argument("--check", action="store_true")
    ab.set_defaults(func=do_autoblock)

    pp = sub.add_parser("probe-profile",
                        help="Read-only: report whether the named firewall profile has any rules.")
    pp.add_argument("--profile", required=True)
    pp.set_defaults(func=do_probe_profile)

    g = sub.add_parser("geoip",
                       help="Firewall.Geoip set (enable + policy + country allowlist).")
    g.add_argument("--enable")
    g.add_argument("--policy", choices=["allow", "deny"],
                   help="`allow` = whitelist mode (only listed countries allowed); "
                        "`deny` = blacklist mode. For 'US is the floor' use allow.")
    g.add_argument("--countries",
                   help="Comma-separated ISO 3166-1 alpha-2 codes, e.g. 'US' or 'US,CA'.")
    g.add_argument("--check", action="store_true")
    g.set_defaults(func=do_geoip)

    pg = sub.add_parser("probe-geoip",
                        help="Read-only: dump current Firewall.Geoip object (real field names).")
    pg.set_defaults(func=do_probe_geoip)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
