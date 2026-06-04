#!/usr/bin/env python3
"""Apply DSM's OIDC SSO-Client config idempotently via synowebapi. One subcommand:

  oidc   Point DSM's web login (`:6021`) at an external OpenID Connect IdP
         (Authentik), and optionally make SSO the DEFAULT login method. Maps the
         spec/e4e-nas/sso.yml `oidc:` block onto the DSM SSO-Client API. FULL-OBJECT
         pattern (partial = err 2001, like SYNO.Core.Web.DSM), so GET → overlay the
         managed keys → SET, only on drift.

Invoked by the synology_sso ansible role via the `script` module (runs on DSM's
Python 3.8 — same constraint as apply_dsm_web/_smb/_nfs). Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>; the role keys
changed/failed off that.

The OIDC client_secret is read from the DSM_SSO_OIDC_CLIENT_SECRET env var (NOT
argv — same rationale as apply_garage.py: keep it off `ps`/argv/ansible logs). It
is WRITE-ONLY: DSM's GET does not return the secret, so we can't diff on it — it's
always included in the SET payload when enabling, and never printed in drift output.

╔════════════════════════════════════════════════════════════════════════════╗
║ DISCOVERY REQUIRED BEFORE FIRST APPLY — the DSM SSO-Client API name and       ║
║ field names below are a BEST-GUESS (no public DSM 7.3 API doc; the SSO-Client ║
║ applet is newer than the surfaces the other synology_* roles wrap). This is   ║
║ the sanctioned "discovery is the only exception" step (CLAUDE.md / ADR 0001):  ║
║   1. In DSM web → Control Panel → "SSO Client", open the OIDC profile wizard.  ║
║   2. Capture the Save POST with Chrome DevTools (Network tab) — note the real  ║
║      api= name, method, version, and the exact field keys.                     ║
║   3. Flip SSO_API / OIDC_FIELDS below to match, then `--check` against the NAS ║
║      (read-only GET) to confirm the GET shape, THEN apply.                      ║
║ Same playbook the cert role used for `SAN_list` and app_portal used for        ║
║ OUT_KEYS. Until verified, treat this role as scaffolding — do NOT flip it on    ║
║ in the unattended converge.                                                     ║
╚════════════════════════════════════════════════════════════════════════════╝
"""
import argparse
import json
import os
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"

# BEST-GUESS — verify via DevTools capture (see banner above).
SSO_API = "SYNO.Core.SSO.Client"
SSO_API_VERSION = "1"

# Env var carrying the OIDC client_secret (write-only; never argv).
_SECRET_ENV_VAR = "DSM_SSO_OIDC_CLIENT_SECRET"


def _exec(api, *params):
    """Run synowebapi and parse its JSON (preamble is on stderr; stdout is pure JSON)."""
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
    """dict -> synowebapi key=value tokens (bool->true/false, null skipped, list/dict->JSON,
    bare strings JSON-quoted so DSM gets the exact value — same rule as apply_dsm_web)."""
    args = []
    for key, val in data.items():
        if val is None:
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif isinstance(val, (dict, list)):
            val = json.dumps(val)
        elif isinstance(val, str):
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


# --- oidc (DSM SSO-Client, full-object) -------------------------------------------
# (argparse-flag, DSM field, value cast). The client_secret is handled separately
# (write-only, from env) so it never appears here or in drift output.
OIDC_FIELDS = [
    ("enable",            "enable",             _bool),
    # Force OIDC profile type; DSM SSO-Client also supports SAML.
    ("provider_name",     "provider_name",      str),
    ("client_id",         "app_id",             str),
    ("issuer_url",        "well_known_url",      str),   # DSM appends /.well-known/... itself on some builds; verify
    ("redirect_uri",      "redirect_uri",       str),
    # Which OIDC claim DSM matches against a DSM/AD account (winbind sAMAccountName).
    ("account_attribute", "account_attribute",  str),
    # "default to authentik instead of the password ui": make SSO the default
    # login. The local password form stays REACHABLE (DSM keeps a fallback link)
    # so the break-glass e4e-admin + SSH key-only path can't be locked out.
    ("set_as_default",    "set_as_default",     _bool),
]


def do_oidc(a):
    desired = {dsm: cast(v) for (flag, dsm, cast) in OIDC_FIELDS
               if (v := getattr(a, flag, None)) is not None}

    # Secret: required only when enabling. Write-only (not diffed, not printed).
    secret = os.environ.get(_SECRET_ENV_VAR, "")
    enabling = desired.get("enable") is True
    if enabling and not secret:
        print("FAIL " + json.dumps({"reason": "OIDC enabled but secret env unset",
                                    "vars": [_SECRET_ENV_VAR]}))
        return 1

    current = _exec(SSO_API, "version=" + SSO_API_VERSION, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        if secret:
            current["app_secret"] = secret      # write-only; never in `drift`
        return _exec(SSO_API, "version=" + SSO_API_VERSION, "method=set",
                     *_args_from(current))

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM OIDC SSO-Client config via synowebapi.",
                                 allow_abbrev=False)
    sub = ap.add_subparsers(dest="cmd", required=True)

    o = sub.add_parser("oidc", help="DSM OIDC SSO-Client (Authentik login)",
                       allow_abbrev=False)
    for flag, _dsm, _cast in OIDC_FIELDS:
        o.add_argument("--" + flag.replace("_", "-"), dest=flag)
    o.add_argument("--check", action="store_true")
    o.set_defaults(func=do_oidc)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
