#!/usr/bin/env python3
"""Apply DSM NFS config idempotently via synowebapi. Two subcommands:

  global       SYNO.Core.FileServ.NFS set — enable NFS / NFSv4 / v4 domain. Like SMB,
               `set` needs the FULL object (partial = error 2001), so GET -> overlay ->
               SET, only on drift.
  share-rules  SYNO.Core.FileServ.NFS.SharePrivilege — per-share export rules. `load`
               (param `share_name=`) returns {"rule":[...]}, `save` takes the same list
               back. Load/save are symmetric, so the spec carries DSM-native rule objects.

A rule object (validated on the DSM 7.3 rig) has exactly these keys:
  client          host / IP / subnet string
  privilege       "rw" | "ro"
  root_squash     "root" (= no_root_squash on the wire; DSM's confusing short value)
  async           bool
  insecure        bool   (allow non-privileged source ports)
  crossmnt        bool
  security_flavor {"sys":bool,"kerberos":bool,"kerberos_integrity":bool,"kerberos_privacy":bool}

Invoked by the synology_nfs ansible role via the `script` module (runs on DSM's
Python 3.8). Prints OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>;
the role keys changed/failed off that. synowebapi (/usr/syno/bin) prints a
`[Line N] Exec WebAPI:` preamble before its JSON, which we strip.
"""

import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
GLOBAL_API = "SYNO.Core.FileServ.NFS"
PRIV_API = "SYNO.Core.FileServ.NFS.SharePrivilege"


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


def _args_from(data):
    """Turn a dict into synowebapi key=value args (bool->true/false, dict/list->JSON)."""
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


def _result(drift, check, apply_fn):
    """Shared OK/WOULD-CHANGE/CHANGED/FAIL flow given a drift dict and an apply callable."""
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


def do_global(a):
    desired = {}
    if a.enable is not None:
        desired["enable_nfs"] = _bool(a.enable)
    if a.nfsv4 is not None:
        desired["enable_nfs_v4"] = _bool(a.nfsv4)
    if a.v4_domain is not None:
        desired["nfs_v4_domain"] = a.v4_domain

    current = _exec(GLOBAL_API, "version=1", "method=get")["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if _coerce_like(v, current.get(k)) != v
    }

    def apply():
        current.update(desired)
        return _exec(GLOBAL_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


def _norm(rules):
    """Order-insensitive canonical form for comparing rule lists."""
    return json.dumps(sorted(rules, key=lambda r: r.get("client", "")), sort_keys=True)


def do_share_rules(a):
    desired = json.loads(a.rules)
    current = _exec(PRIV_API, "version=1", "method=load", "share_name=" + a.share)["data"]["rule"]
    drift = {} if _norm(current) == _norm(desired) else {"current": current, "desired": desired}

    def apply():
        return _exec(
            PRIV_API,
            "version=1",
            "method=save",
            "share_name=" + a.share,
            "rule=" + json.dumps(desired),
        )

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM NFS config via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("global", help="global NFS service settings")
    g.add_argument("--enable")
    g.add_argument("--nfsv4")
    g.add_argument("--v4-domain", dest="v4_domain")
    g.add_argument("--check", action="store_true")
    g.set_defaults(func=do_global)

    r = sub.add_parser("share-rules", help="per-share export rules")
    r.add_argument("--share", required=True)
    r.add_argument("--rules", required=True, help="JSON array of DSM rule objects")
    r.add_argument("--check", action="store_true")
    r.set_defaults(func=do_share_rules)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
