#!/usr/bin/env python3
"""Apply DSM AD domain join (KRG.LOCAL) + winbind config idempotently.

Subcommands:
  domain-config   SYNO.Core.Directory.Domain set (v1) — realm + DC + idmap +
                  allowed/admin groups. FULL-OBJECT (partial = err 2001).
  test-join       SYNO.Core.Directory.Domain.Join test (v1) — read-only check.
                  Prints "JOINED <realm>" / "NOT-JOINED <reason>".
  join            SYNO.Core.Directory.Domain.Join start (v1) — one-shot join.
                  Needs Domain Admin creds; password is on argv (--no-log).

Invoked by synology_ad ansible role via `script` (DSM py3.8). Same
OK/WOULD-CHANGE/CHANGED/FAIL contract as the other apply_*.py helpers.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip
OUT_KEYS on first-apply drift):
  realm                  -> realm
  domain                 -> nbns_name (DSM's "domain NETBIOS name" slot — verify)
  dc_host                -> server_address
  dc_ip                  -> server_ip
  ou                     -> ou
  idmap_mode             -> idmap_type     ("rid"|"autorid")
  idmap_uid_range        -> idmap_uid
  idmap_gid_range        -> idmap_gid
  allowed_groups         -> allowed_groups
  admin_groups           -> domain_admin_groups
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
DOMAIN_API = "SYNO.Core.Directory.Domain"
JOIN_API = "SYNO.Core.Directory.Domain.Join"

OUT_KEYS = {
    "realm":          "realm",
    "domain":         "nbns_name",
    "dc_host":        "server_address",
    "dc_ip":          "server_ip",
    "ou":             "ou",
    "idmap_mode":     "idmap_type",
    "idmap_uid":      "idmap_uid",
    "idmap_gid":      "idmap_gid",
    "allowed_groups": "allowed_groups",
    "admin_groups":   "domain_admin_groups",
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


# --- domain-config (SYNO.Core.Directory.Domain, full-object) ----------------
def _normalize(v):
    if isinstance(v, list):
        return sorted(v)
    return v


def do_domain_config(a):
    allowed = json.loads(a.allowed_groups) if a.allowed_groups else []
    admins = json.loads(a.admin_groups) if a.admin_groups else []
    for label, val in (("--allowed-groups", allowed), ("--admin-groups", admins)):
        if not isinstance(val, list):
            raise SystemExit("%s must be a JSON list" % label)

    desired = {
        OUT_KEYS["realm"]:          a.realm,
        OUT_KEYS["domain"]:         a.domain,
        OUT_KEYS["dc_host"]:        a.dc_host,
        OUT_KEYS["dc_ip"]:          a.dc_ip,
        OUT_KEYS["ou"]:             a.ou,
        OUT_KEYS["idmap_mode"]:     a.idmap_mode,
        OUT_KEYS["idmap_uid"]:      a.idmap_uid_range,
        OUT_KEYS["idmap_gid"]:      a.idmap_gid_range,
        OUT_KEYS["allowed_groups"]: sorted(allowed),
        OUT_KEYS["admin_groups"]:   sorted(admins),
    }
    current = _exec(DOMAIN_API, "version=1", "method=get")["data"]
    # Validated 2026-05-31 against e4e-nas: when NOT joined, DSM's
    # Directory.Domain GET returns only {"enable_domain": false} — none
    # of the realm/dc_host/idmap fields exist yet, and SET on them
    # returns success=true but silently drops the values. So a pre-join
    # apply would report CHANGED every run while nothing persisted.
    #
    # The "stage Domain config" intent was to pre-populate fields so the
    # eventual join is one-step, but this DSM version doesn't support
    # that — the staging IS the join, and the join needs creds (handled
    # by do_join). Until joined, this subcommand is a no-op + WARN.
    if not current.get("enable_domain", False):
        sys.stderr.write(
            "WARN: Directory.Domain config staging deferred — DSM returns "
            "only {enable_domain: false} until joined, and SET silently "
            "drops realm/dc_host/idmap fields when not joined. Run "
            "`ansible-playbook ... -e ad_join_password='<pass>'` to join; "
            "the join subcommand passes the full config in one shot.\n")
        print("OK no-change (deferred — not joined)")
        return 0

    # Compare lists order-invariantly.
    cur_norm = {k: _normalize(v) for k, v in current.items()}
    drift = {k: {"current": cur_norm.get(k), "desired": v}
             for k, v in desired.items() if cur_norm.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(DOMAIN_API, "version=1", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


# --- test-join (read-only) --------------------------------------------------
def do_test_join(_a):
    """Print JOINED <realm> on success, NOT-JOINED <reason> otherwise.
    The role gates whether to attempt a join on the presence of the JOINED token.
    """
    try:
        res = _exec(JOIN_API, "version=1", "method=test")
    except RuntimeError as e:
        print("NOT-JOINED " + str(e)[:200])
        return 0
    if res.get("success") and res.get("data", {}).get("joined"):
        realm = res["data"].get("realm", "")
        print("JOINED " + realm)
        return 0
    print("NOT-JOINED " + json.dumps(res.get("data", {})))
    return 0


# --- join (one-shot; needs creds) -------------------------------------------
def do_join(a):
    if not a.join_password:
        print("FAIL " + json.dumps({"error": "join requires --join-password"}))
        return 1
    res = _exec(
        JOIN_API, "version=1", "method=start",
        "realm=" + a.realm,
        "server_address=" + a.dc_host,
        "user=" + a.join_user,
        "password=" + a.join_password,
    )
    if res.get("success"):
        print("CHANGED " + json.dumps({"joined": a.realm}))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM AD join + winbind config via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("domain-config", help="Directory.Domain (realm + DC + idmap + groups)")
    d.add_argument("--realm", required=True)
    d.add_argument("--domain", required=True)
    d.add_argument("--dc-host", dest="dc_host", required=True)
    d.add_argument("--dc-ip", dest="dc_ip", required=True)
    d.add_argument("--ou", required=True)
    d.add_argument("--idmap-mode", dest="idmap_mode", required=True)
    d.add_argument("--idmap-uid-range", dest="idmap_uid_range", required=True)
    d.add_argument("--idmap-gid-range", dest="idmap_gid_range", required=True)
    d.add_argument("--allowed-groups", dest="allowed_groups", required=True, help="JSON list")
    d.add_argument("--admin-groups", dest="admin_groups", required=True, help="JSON list")
    d.add_argument("--check", action="store_true")
    d.set_defaults(func=do_domain_config)

    t = sub.add_parser("test-join", help="Read-only join status check")
    t.set_defaults(func=do_test_join)

    j = sub.add_parser("join", help="One-shot AD join (needs creds)")
    j.add_argument("--realm", required=True)
    j.add_argument("--dc-host", dest="dc_host", required=True)
    j.add_argument("--join-user", dest="join_user", required=True)
    j.add_argument("--join-password", dest="join_password", required=True)
    j.set_defaults(func=do_join)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
