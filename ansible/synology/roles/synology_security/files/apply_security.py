#!/usr/bin/env python3
"""Apply DSM security perimeter (firewall + auto-block) idempotently via synowebapi.
Subcommands:
  firewall     — SYNO.Core.Security.Firewall set (enable, profile_name) — full-object.
  fw-conf      — SYNO.Core.Security.Firewall.Conf set (port_check) — full-object.
  autoblock    — SYNO.Core.Security.AutoBlock set (enable, attempts, within_mins,
                 expire_day) — full-object.

Per-rule firewall config (Firewall.Rules.save_start/save_status/save_stop) and
AutoBlock allow/deny lists (AutoBlock.Rules) are NOT yet covered — both error on
the CLI surface (Rules.save_start with concrete rule objects segfaults
synowebapi --exec; AutoBlock.Rules errors 5100). The synology_security tasks
debug-surface the intended state (geoip + autoblock allow-list) so an operator
can verify in the DSM UI; the apply lands when those API gaps are bridged via
the HTTP webapi path. See the DSM-side runbook (`docs/e4e-nas-dsm.md`) for the
manual UI steps in the meantime.

Read-only diagnostics (no SET; safe to run any time):
  probe-profile — read Firewall.Profile, report whether active profile has rules.
  probe-geoip   — surface DSM's geoip state: confirm Firewall.Geoip.list works,
                  dump current per-adapter rule policies + whether any rule uses
                  set_type=geoip. Used by the role to give operators a visible
                  snapshot until the rule-push API is implemented.
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
# DSM ships a per-country firewall feature but the API surface is read-only on
# the CLI path we have. The shape (empirically probed on DSM 7.2.2):
#
#   SYNO.Core.Security.Firewall.Geoip
#     methods: list (countries picker), get (per-country IP-range lookup
#              for the UI's country-detail dialog — needs country_code +
#              is_ipv6 params).
#     There is NO Geoip set method. The descriptor lists only {list, get}.
#
# Geoip is therefore NOT a standalone toggle — it lives as a per-RULE source
# type on a Firewall.Profile rule:
#   { "enabled": true, "service_policy": "allow",
#     "set_type": "geoip", "src": "US", ... }
# Pushing that rule goes through SYNO.Core.Security.Firewall.Rules.save_start
# (adapter + policy + rules → task_id; poll save_status; save_stop). That call
# DOES work for empty rules, but synowebapi --exec SEGFAULTS on rule objects
# with concrete fields (DSM bug in the CLI parser, reproduced on 7.2.2). The
# DSM web UI uses the HTTP webapi path with a session cookie — that's the
# path future work should take. synofirewall --import is NOT a safe alternative:
# it deletes /usr/syno/etc/firewall.d/*.json on any parse failure (witnessed
# 2026-05-30; restored from /usr/syno/etc.defaults/firewall.d/).
#
# Until the HTTP-path implementation lands, geoip enforcement is a MANUAL UI
# step (Control Panel > Security > Firewall > Edit default profile > +Create
# rule: source = "Specific IP from country" / United States / action = Allow,
# then default-deny everything else). Runbook: docs/e4e-nas-dsm.md.
#
# probe-geoip surfaces enough state for an operator to verify the manual setup:
# Firewall.Geoip.list (confirms geoip subsystem is available), Firewall.get
# (active profile + enabled), and per-adapter rule policies + a count of any
# rule using set_type=geoip.


def do_probe_geoip(a):
    """Read-only: surface DSM's geoip-related state for operator verification.
    Prints one of:
      GEOIP-OK <json>         — JSON with: countries_available (Geoip.list
                                worked), firewall (enable + active profile),
                                per_adapter (rules.load summary for each
                                configured adapter), geoip_rule_count (rules
                                with set_type=geoip across adapters).
      GEOIP-UNKNOWN <reason>  — couldn't read; operator should check DSM logs.
    """
    out = {"countries_available": None, "firewall": None, "per_adapter": [],
           "geoip_rule_count": 0}
    try:
        listing = _exec("SYNO.Core.Security.Firewall.Geoip", "version=1", "method=list")
        if listing.get("success"):
            out["countries_available"] = len(listing.get("data", {}).get("countries", []))
        fw = _exec("SYNO.Core.Security.Firewall", "version=1", "method=get")
        if fw.get("success"):
            out["firewall"] = fw.get("data", {})
        adapters = _exec("SYNO.Core.Security.Firewall.Adapter",
                         "version=1", "method=list")
        names = adapters.get("data", {}).get("adapter_names", []) if adapters.get("success") else []
        for name in names:
            rl = _exec("SYNO.Core.Security.Firewall.Rules", "version=1",
                       "method=load", "adapter=\"%s\"" % name)
            d = rl.get("data", {}) if rl.get("success") else {}
            rules = d.get("rules") or []
            out["per_adapter"].append({
                "adapter": name, "policy": d.get("policy"),
                "total": d.get("total", 0),
            })
            out["geoip_rule_count"] += sum(
                1 for r in rules if isinstance(r, dict) and r.get("set_type") == "geoip"
            )
    except RuntimeError as e:
        print("GEOIP-UNKNOWN " + json.dumps({"error": str(e)[:200]}))
        return 0
    print("GEOIP-OK " + json.dumps(out, sort_keys=True))
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

    pg = sub.add_parser("probe-geoip",
                        help="Read-only: surface DSM geoip-related state "
                             "(countries listable, firewall enable/profile, "
                             "per-adapter rule policies, count of geoip rules).")
    pg.set_defaults(func=do_probe_geoip)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
