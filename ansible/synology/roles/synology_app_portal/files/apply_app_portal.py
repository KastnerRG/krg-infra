#!/usr/bin/env python3
"""Apply DSM Application Portal config idempotently via synowebapi. Subcommands:

  config           SYNO.Core.AppPortal.Config set v1 (show_titlebar) — full-object.
  reverse-proxy    SYNO.Core.AppPortal.ReverseProxy create/update/delete v1 — list of
                   entries diffed by frontend host:port. Each mutation passes the whole
                   entry as a single `entry=<json>` param (wizard-captured); live entries
                   carry a DSM `UUID` used to target update/delete. Idempotent declarative
                   sync: spec → live; create new, update changed, delete extras.
  access-control   SYNO.Core.AppPortal.AccessControl create/update/delete v1 — same model.

Per-app portal entries (SYNO.Core.AppPortal) have a more complex shape (alias, fqdn,
HSTS, ACL ref) — `apps` subcommand is reserved; declarative sync semantics for an
existing-entries set are nontrivial and DSM-defined ids matter. Add when the rebuild
scope requires it; meanwhile the spec's `portal_apps` is documentation.
"""

import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"


def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params], capture_output=True, text=True)
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


def do_config(a):
    desired = {}
    if a.show_titlebar is not None:
        desired["show_titlebar"] = _bool(a.show_titlebar)

    api = "SYNO.Core.AppPortal.Config"
    current = _exec(api, "version=1", "method=get")["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

    def apply():
        current.update(desired)
        return _exec(api, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


def _list_key(entry):
    """Stable identity for a list-entry diff. A reverse-proxy entry gets a UUID
    `id` from DSM on create, so a spec entry can't carry one — key those by their
    frontend host:port (unique per entry, stable across spec↔live). Everything
    else keys by DSM id, then alias/name."""
    fe = entry.get("frontend")
    if isinstance(fe, dict) and fe.get("fqdn"):
        return "fe:%s:%s" % (str(fe["fqdn"]).lower(), fe.get("port"))
    return entry.get("id") or entry.get("alias") or entry.get("name")


def _covered(desired, live):
    """True when every key in `desired` is present in `live` with an equal value
    (recursive for nested dicts like frontend/backend). Lets DSM-filled fields
    (the assigned id, defaulted timeouts, …) NOT register as drift, so a spec
    that carries a subset of the live object converges idempotently instead of
    showing perpetual "update"."""
    if isinstance(desired, dict):
        return isinstance(live, dict) and all(
            k in live and _covered(v, live[k]) for k, v in desired.items()
        )
    return desired == live


def _diff_lists(api, entries_key, desired_list, check):
    """Declarative sync of a list-of-entries API (create / update / delete by id)."""
    live = _exec(api, "version=1", "method=list")["data"].get(entries_key, [])
    live_by_id = {_list_key(e): e for e in live if _list_key(e)}
    desired_by_id = {_list_key(e): e for e in desired_list if _list_key(e)}

    creates = [e for k, e in desired_by_id.items() if k not in live_by_id]
    deletes = [live_by_id[k] for k in (set(live_by_id) - set(desired_by_id))]
    # Subset compare (not `!=`): DSM returns the live object with its assigned id
    # + defaulted fields the spec omits; only flag an update when a value the
    # spec DOES set differs. Otherwise every run would re-"update" forever.
    updates = [
        (k, desired_by_id[k])
        for k in (set(live_by_id) & set(desired_by_id))
        if not _covered(desired_by_id[k], live_by_id[k])
    ]

    drift = {}
    if creates:
        drift["create"] = creates
    if updates:
        drift["update"] = [{"id": k, "from": live_by_id[k], "to": d} for k, d in updates]
    if deletes:
        drift["delete"] = deletes

    def apply():
        # Return the first failed _exec result so _result() reports FAIL and
        # the role's failed_when fires. Hardcoding {"success": True} would
        # swallow err 2001 / bad-id / etc. and silently report CHANGED.
        #
        # PAYLOAD SHAPE (DSM 7.3, wizard-captured on e4e-nas 2026-06-04): the
        # AppPortal entry-list APIs take the WHOLE entry as a single JSON param
        # `entry=<json>` — NOT the fields flattened as separate params (that got
        # err 4151). Live entries carry a DSM-assigned `UUID` (not `id`), used to
        # target update/delete. CREATE is wizard-verified; update/delete mirror
        # the same entry/UUID shape but the method names are not yet captured —
        # in steady state neither runs (the spec is a subset of live → no-change).
        for e in creates:
            r = _exec(api, "version=1", "method=create", "entry=" + json.dumps(e))
            if not r.get("success"):
                return r
        for k, d in updates:
            # Inject the live UUID so DSM knows which entry to mutate (the spec
            # carries none — it's DSM-assigned on create).
            args = dict(d)
            luid = live_by_id[k].get("UUID") or live_by_id[k].get("id")
            if luid is not None and "UUID" not in args:
                args["UUID"] = luid
            r = _exec(api, "version=1", "method=update", "entry=" + json.dumps(args))
            if not r.get("success"):
                return r
        for e in deletes:
            # Delete by the DSM-assigned UUID; fall back to alias/name (matches
            # the same _list_key the diff uses, so we don't send an empty key).
            uid = e.get("UUID") or e.get("id")
            del_key = (
                {"UUID": uid}
                if uid is not None
                else {"alias": e["alias"]}
                if e.get("alias") is not None
                else {"name": e["name"]}
                if e.get("name") is not None
                else None
            )
            if del_key is None:
                return {
                    "success": False,
                    "error": {"reason": "delete: no UUID/alias/name", "entry": e},
                }
            r = _exec(api, "version=1", "method=delete", *_args_from(del_key))
            if not r.get("success"):
                return r
        return {"success": True}

    return _result(drift, check, apply)


def do_reverse_proxy(a):
    desired = json.loads(a.entries)
    return _diff_lists("SYNO.Core.AppPortal.ReverseProxy", "entries", desired, a.check)


def do_access_control(a):
    desired = json.loads(a.entries)
    return _diff_lists("SYNO.Core.AppPortal.AccessControl", "entries", desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("config")
    c.add_argument("--show-titlebar", dest="show_titlebar")
    c.add_argument("--check", action="store_true")
    c.set_defaults(func=do_config)

    rp = sub.add_parser("reverse-proxy")
    rp.add_argument("--entries", required=True, help="JSON array of reverse-proxy entries")
    rp.add_argument("--check", action="store_true")
    rp.set_defaults(func=do_reverse_proxy)

    ac = sub.add_parser("access-control")
    ac.add_argument("--entries", required=True, help="JSON array of access-control entries")
    ac.add_argument("--check", action="store_true")
    ac.set_defaults(func=do_access_control)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
