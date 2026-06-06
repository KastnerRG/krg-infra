#!/usr/bin/env python3
"""Apply DSM's OIDC SSO-Client config idempotently via synowebapi.

  oidc   Point DSM's web login (`:6021`) at an external OpenID Connect IdP
         (Authentik) and optionally make SSO the DEFAULT login, from the
         spec/e4e-nas/sso.yml `oidc:` block. Drives THREE DSM APIs:

           - SYNO.Core.Directory.OIDC.SSO  (method=set, profile="oidc")
             The OIDC profile: name / well-known URL / client id+secret /
             redirect / scope / user-claim / allow-local-user.

           - SYNO.Core.Directory.SSO.Profile (method=set)
             sso_profile="oidc" + sso_enable=true — ACTIVATES the OIDC profile and
             switches the SSO service on. This is what makes DSM render the login
             button; configuring OIDC.SSO alone does NOT. (NOT to be confused with
             SYNO.Core.Directory.SSO, the Synology-SSO-Server profile.)

           - SYNO.Core.Directory.SSO.Setting (method=set)
             sso_default_login — the "default to SSO instead of the password
             form" toggle (a separate control from the profile config).

         Each API is GET -> diff -> SET, only on drift. They're diffed and applied
         independently, so flipping just the default-login toggle doesn't
         needlessly rewrite the OIDC profile (or re-send the secret).

Invoked by the synology_sso ansible role via the `script` module (DSM Python 3.8
— same constraint as apply_dsm_web/_smb/_nfs). Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>; the role keys
changed/failed off that.

The OIDC client_secret is read from the DSM_SSO_OIDC_CLIENT_SECRET env var (NOT
argv — keep it off `ps`/argv/ansible logs, same as apply_garage.py). DSM's OIDC
GET DOES return the secret in plaintext, so we diff it silently to catch a
rotation — but its value is never printed (drift shows `"<changed>"` only).

API shape + field names + the JSON-quoted value encoding were VERIFIED 2026-06-05
from a Chrome DevTools capture of the DSM "SSO Client" wizard Save + live probing.
The OIDC.SSO set is partial (managed oidc_* fields + profile). DSM stores
oidc_authorization_endpoint + oidc_token_endpoint explicitly (it does NOT derive
them from oidc_wellknown on an API set), but fetches jwks/userinfo from
oidc_wellknown at runtime.
"""
import argparse
import json
import os
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"

# OIDC profile config (configure + activate via profile="oidc").
OIDC_API = "SYNO.Core.Directory.OIDC.SSO"
OIDC_API_VERSION = "1"
OIDC_PROFILE = "oidc"

# Default-login toggle ("default to SSO instead of the password form").
SETTING_API = "SYNO.Core.Directory.SSO.Setting"
SETTING_API_VERSION = "1"
DEFAULT_LOGIN_FIELD = "sso_default_login"

# Activation: select OIDC as the active SSO type AND switch the service on. This
# is the object the login page reads to render the SSO button — configuring
# OIDC.SSO alone is NOT enough. {sso_enable: bool, sso_profile: "<type>"}; the
# available types come from SSO.Profile `list` (["azure","websphere","oidc"]).
# (Do NOT confuse with SYNO.Core.Directory.SSO — that's the Synology-SSO-*Server*
# profile, name "Synology SSO", with appid/host; a different SSO type.)
ACTIVATE_API = "SYNO.Core.Directory.SSO.Profile"
ACTIVATE_API_VERSION = "1"
ACTIVATE_PROFILE = "oidc"
SSO_ENABLE_FIELD = "sso_enable"
SSO_PROFILE_FIELD = "sso_profile"

# OIDC client_secret: from env (write-only on argv), DSM field name.
_SECRET_ENV_VAR = "DSM_SSO_OIDC_CLIENT_SECRET"
_SECRET_FIELD = "oidc_client_secret"


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


# (argparse flag, DSM field, value cast). The client_secret (write-from-env) and
# the constant `profile` are handled separately. `oidc_wellknown` is the full
# OIDC discovery URL (issuer + /.well-known/openid-configuration) — the role
# derives it from spec.issuer_url and passes it via --wellknown.
OIDC_FIELDS = [
    ("provider_name",          "oidc_name",                   str),
    ("wellknown",              "oidc_wellknown",              str),
    # DSM does NOT auto-derive these from oidc_wellknown on an API set (the wizard
    # fetches the discovery doc client-side and fills them in) — so we set them
    # explicitly, else DSM can't build the authorize redirect ("SSO not properly
    # configured"). jwks/userinfo ARE fetched from oidc_wellknown at runtime.
    ("authorization_endpoint", "oidc_authorization_endpoint", str),
    ("token_endpoint",         "oidc_token_endpoint",         str),
    ("client_id",              "oidc_client_id",              str),
    ("redirect_uri",           "oidc_redirect_uri",           str),
    ("scope",                  "oidc_scope",                  str),
    ("account_attribute",      "oidc_user_claim",             str),
    ("allow_local_user",       "oidc_allow_local_user",       _bool),
]


def _exec(api, version, method, *params):
    """Run synowebapi and parse its JSON (preamble on stderr; stdout is pure JSON)."""
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + api, "version=" + version,
         "method=" + method, *params],
        capture_output=True, text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _args_from(data):
    """dict -> synowebapi key=value tokens. bool -> true/false (unquoted), null
    skipped, everything else JSON-encoded so DSM receives the exact value — this
    matches the wizard's x-www-form-urlencoded payload (e.g. oidc_name="Authentik",
    oidc_allow_local_user=false)."""
    args = []
    for key, val in data.items():
        if val is None:
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        else:
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


def do_oidc(a):
    if not _bool(getattr(a, "enable", "true")):
        # Disabling OIDC SSO is not modeled (no captured 'disable' shape) — and
        # the role's `when: enable` guard means we're not normally called here.
        # Leave DSM untouched rather than guessing a destructive call.
        print("OK no-change")
        return 0

    secret = os.environ.get(_SECRET_ENV_VAR, "")
    if not secret:
        print("FAIL " + json.dumps({"reason": "OIDC enabled but secret env unset",
                                    "vars": [_SECRET_ENV_VAR]}))
        return 1

    desired_oidc = {dsm: cast(v) for (flag, dsm, cast) in OIDC_FIELDS
                    if (v := getattr(a, flag, None)) is not None}
    desired_default = _bool(a.set_as_default)

    cur_oidc = _exec(OIDC_API, OIDC_API_VERSION, "get")["data"]
    cur_activate = _exec(ACTIVATE_API, ACTIVATE_API_VERSION, "get")["data"]
    cur_setting = _exec(SETTING_API, SETTING_API_VERSION, "get")["data"]

    # OIDC profile drift (visible fields + the silently-diffed secret).
    oidc_drift = {k: {"current": cur_oidc.get(k), "desired": v}
                  for k, v in desired_oidc.items() if cur_oidc.get(k) != v}
    if cur_oidc.get(_SECRET_FIELD) != secret:
        oidc_drift[_SECRET_FIELD] = "<changed>"      # value redacted, never printed

    # Activation drift — select OIDC + switch on. Without this DSM shows no login
    # button (the profile alone isn't enough). We only reach here when enabling.
    activate_drift = {}
    if cur_activate.get(SSO_PROFILE_FIELD) != ACTIVATE_PROFILE:
        activate_drift[SSO_PROFILE_FIELD] = {
            "current": cur_activate.get(SSO_PROFILE_FIELD), "desired": ACTIVATE_PROFILE}
    if cur_activate.get(SSO_ENABLE_FIELD) is not True:
        activate_drift[SSO_ENABLE_FIELD] = {
            "current": cur_activate.get(SSO_ENABLE_FIELD), "desired": True}

    # Default-login toggle drift (independent API).
    setting_drift = {}
    if cur_setting.get(DEFAULT_LOGIN_FIELD) != desired_default:
        setting_drift[DEFAULT_LOGIN_FIELD] = {
            "current": cur_setting.get(DEFAULT_LOGIN_FIELD), "desired": desired_default}

    drift = dict(oidc_drift)
    drift.update(activate_drift)
    drift.update(setting_drift)

    def apply():
        # Order: configure the profile, THEN activate (select+enable), THEN default.
        if oidc_drift:
            payload = dict(desired_oidc)
            payload["profile"] = OIDC_PROFILE          # configure + activate
            payload[_SECRET_FIELD] = secret            # write-only; never in drift
            r = _exec(OIDC_API, OIDC_API_VERSION, "set", *_args_from(payload))
            if not r.get("success"):
                return r
        if activate_drift:
            r = _exec(ACTIVATE_API, ACTIVATE_API_VERSION, "set",
                      *_args_from({SSO_PROFILE_FIELD: ACTIVATE_PROFILE,
                                   SSO_ENABLE_FIELD: True}))
            if not r.get("success"):
                return r
        if setting_drift:
            r = _exec(SETTING_API, SETTING_API_VERSION, "set",
                      *_args_from({DEFAULT_LOGIN_FIELD: desired_default}))
            if not r.get("success"):
                return r
        return {"success": True}

    return _result(drift, a.check, apply)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM OIDC SSO config via synowebapi.",
                                 allow_abbrev=False)
    sub = ap.add_subparsers(dest="cmd", required=True)

    o = sub.add_parser("oidc", help="DSM OIDC SSO (Authentik login)",
                       allow_abbrev=False)
    o.add_argument("--enable", default="true")
    for flag, _dsm, _cast in OIDC_FIELDS:
        o.add_argument("--" + flag.replace("_", "-"), dest=flag)
    o.add_argument("--set-as-default", dest="set_as_default", default="true")
    o.add_argument("--check", action="store_true")
    o.set_defaults(func=do_oidc)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
