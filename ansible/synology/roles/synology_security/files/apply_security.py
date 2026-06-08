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
import http.cookiejar
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WEBAPI = "/usr/syno/bin/synowebapi"


# ---- HTTP webapi client (inlined; matches former dsm_http.py) ----------------
# This was a sibling module (`dsm_http.py`) until 2026-05-31. Ansible's
# `script:` module only ships the named script to the target — not siblings —
# so `from dsm_http import …` fails with ModuleNotFoundError when the role
# runs. Inlining keeps the single-file pattern every other synology_* role
# uses. Tests still cover this surface directly (test_apply_security.py).
#
# Transport details (captured from the DSM 7.3 web UI's XHRs):
#   - POST to https://localhost:6021/webapi/entry.cgi
#   - Content-Type: application/x-www-form-urlencoded
#   - JSON values in form fields are JSON-quoted (name="default", not bare)
#   - X-SYNO-TOKEN header required for state-changing calls; returned by
#     login when enable_syno_token=yes
#   - X-SYNO-HASH is OPTIONAL (server validates only if present — omitted
#     → success). We omit.


class DSMError(Exception):
    """A DSM webapi call returned success=false or non-200 HTTP."""

    def __init__(self, msg, code=None, payload=None):
        super().__init__(msg)
        self.code = code
        self.payload = payload


class DSMSession(object):
    """HTTP webapi session — context-manage to ensure logout on exit."""

    def __init__(self, host="localhost", port=6021, account="e4e-admin", password=None, timeout=30):
        if not password:
            raise ValueError("password is required")
        self.base = "https://%s:%d/webapi/entry.cgi" % (host, port)
        self.account = account
        self._password = password
        self.timeout = timeout
        self.token = None  # X-SYNO-TOKEN, populated by login()
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        cj = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(cj),
        )

    def __enter__(self):
        self.login()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            self.logout()
        except Exception:
            pass  # never mask the original exception

    def _post(self, params, raw_headers=None):
        headers = {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"}
        if self.token:
            headers["X-SYNO-TOKEN"] = self.token
        if raw_headers:
            headers.update(raw_headers)
        data = urllib.parse.urlencode(params).encode("utf-8")
        req = urllib.request.Request(self.base, data=data, headers=headers)
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                body = resp.read()
        except urllib.error.HTTPError as e:
            raise DSMError(
                "HTTP %d on %s" % (e.code, params.get("api", "?")),
                code=e.code,
                payload=e.read()[:300],
            )
        try:
            return json.loads(body)
        except ValueError:
            raise DSMError("non-JSON response on %s" % params.get("api", "?"), payload=body[:300])

    @staticmethod
    def _check(resp, what):
        if not resp.get("success"):
            err = resp.get("error", {})
            raise DSMError(
                "%s failed (code=%s)" % (what, err.get("code")), code=err.get("code"), payload=resp
            )
        return resp.get("data", {})

    def login(self):
        resp = self._post(
            {
                "api": "SYNO.API.Auth",
                "version": "7",
                "method": "login",
                "account": self.account,
                "passwd": self._password,
                "session": "FileStation",
                "format": "cookie",
                "enable_syno_token": "yes",
            }
        )
        data = self._check(resp, "login")
        self.token = data.get("synotoken")
        if not self.token:
            raise DSMError("login succeeded but no SynoToken returned", payload=data)
        return data

    def logout(self):
        if not self.token:
            return
        try:
            self._post({"api": "SYNO.API.Auth", "version": "7", "method": "logout"})
        finally:
            self.token = None

    def call(self, api, method, version=1, **params):
        """Generic webapi call. String params get JSON-quoted (UI convention)."""
        form = {"api": api, "method": method, "version": str(version)}
        for k, v in params.items():
            if isinstance(v, bool):
                form[k] = "true" if v else "false"
            elif isinstance(v, (int, float)):
                form[k] = str(v)
            elif isinstance(v, str):
                form[k] = json.dumps(v)  # JSON-quoted string
            else:
                form[k] = json.dumps(v, separators=(",", ":"))
        return self._post(form)

    def profile_get(self, name):
        return self._check(
            self.call(
                "SYNO.Core.Security.Firewall.Profile",
                "get",
                name=name,
            ),
            "Profile.get(%s)" % name,
        )

    def profile_set(self, profile, applying=False):
        """Save profile (write to /usr/syno/etc/firewall.d/*.json). Not live until profile_apply()."""
        form = {
            "api": "SYNO.Core.Security.Firewall.Profile",
            "method": "set",
            "version": "1",
            "profile": json.dumps(profile, separators=(",", ":")),
            "profile_applying": "true" if applying else "false",
        }
        return self._check(self._post(form), "Profile.set")

    def profile_apply(self, name, poll_interval=0.5, timeout=60):
        """Commit a saved profile to live nftables (Profile.Apply two-phase).

        `profile_applying=False` matches the UI's call — True errors 117 on
        DSM 7.x. The flag is a context hint, not a do-it toggle.
        """
        started = self._check(
            self.call(
                "SYNO.Core.Security.Firewall.Profile.Apply",
                "start",
                name=name,
                profile_applying=False,
            ),
            "Profile.Apply.start",
        )
        task_id = started.get("task_id")
        if not task_id:
            raise DSMError("Profile.Apply.start returned no task_id", payload=started)
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                status = self._check(
                    self.call(
                        "SYNO.Core.Security.Firewall.Profile.Apply",
                        "status",
                        task_id=task_id,
                    ),
                    "Profile.Apply.status",
                )
                if status.get("finish"):
                    return status
                time.sleep(poll_interval)
            raise DSMError("Profile.Apply timed out after %ds (task=%s)" % (timeout, task_id))
        finally:
            try:
                self.call("SYNO.Core.Security.Firewall.Profile.Apply", "stop")
            except DSMError:
                pass


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


def apply_full_object(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

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
    out = {"countries_available": None, "firewall": None, "per_adapter": [], "geoip_rule_count": 0}
    try:
        listing = _exec("SYNO.Core.Security.Firewall.Geoip", "version=1", "method=list")
        if listing.get("success"):
            out["countries_available"] = len(listing.get("data", {}).get("countries", []))
        fw = _exec("SYNO.Core.Security.Firewall", "version=1", "method=get")
        if fw.get("success"):
            out["firewall"] = fw.get("data", {})
        adapters = _exec("SYNO.Core.Security.Firewall.Adapter", "version=1", "method=list")
        names = adapters.get("data", {}).get("adapter_names", []) if adapters.get("success") else []
        for name in names:
            rl = _exec(
                "SYNO.Core.Security.Firewall.Rules",
                "version=1",
                "method=load",
                'adapter="%s"' % name,
            )
            d = rl.get("data", {}) if rl.get("success") else {}
            rules = d.get("rules") or []
            out["per_adapter"].append(
                {
                    "adapter": name,
                    "policy": d.get("policy"),
                    "total": d.get("total", 0),
                }
            )
            out["geoip_rule_count"] += sum(
                1 for r in rules if isinstance(r, dict) and r.get("set_type") == "geoip"
            )
    except RuntimeError as e:
        print("GEOIP-UNKNOWN " + json.dumps({"error": str(e)[:200]}))
        return 0
    print("GEOIP-OK " + json.dumps(out, sort_keys=True))
    return 0


# --- Firewall.Profile.set + Profile.Apply via HTTP webapi --------------------
# The CLI `synowebapi --exec ... Firewall.Rules.save_start` SEGFAULTS on rule
# objects with concrete fields (DSM 7.2.2 parser bug, reproduced; synoscgi
# also crashes via that path → nginx 502). The DSM web UI uses a different
# API entirely: `Firewall.Profile.set` (full-profile push) followed by
# `Firewall.Profile.Apply.start/status/stop` (two-phase commit) over the HTTP
# webapi. dsm_http.DSMSession is the stdlib client for that path.
#
# This subcommand is the IaC firewall-rule push: read current Profile.get,
# MERGE the spec's per-adapter blocks over it (preserves unmanaged adapters
# — operator can keep manual per-adapter overrides without us nuking them),
# diff, push if changed. Two-phase apply commits to live nftables.
#
# Anti-lockout: refuses to apply if the merged target would leave the active
# profile's `global` adapter with policy=deny + no allow rules (would block
# the SSH session this play runs over).
def do_firewall_profile(a):
    desired_adapters = json.loads(a.desired)  # {adapter: {policy, rules}, ...}
    if not isinstance(desired_adapters, dict):
        print("FAIL desired must be a JSON object of {adapter: {policy, rules}}")
        return 1
    password = a.password or os.environ.get("DSM_PASSWORD") or ""
    if not password:
        print("FAIL no password supplied (pass --password on argv or set DSM_PASSWORD env)")
        return 1

    try:
        with DSMSession(account=a.account, password=password) as s:
            current = s.profile_get(a.profile_name)
            # Merge: replace declared adapters, preserve the rest + the name key
            target = dict(current)
            target["name"] = a.profile_name
            for adapter, block in desired_adapters.items():
                target[adapter] = block

            # Per-adapter drift — only on adapters we manage
            drift = {
                ad: {"current": current.get(ad), "desired": target[ad]}
                for ad in desired_adapters
                if current.get(ad) != target[ad]
            }

            if not drift:
                print("OK no-change")
                return 0

            # Anti-lockout: if any MANAGED adapter would have a default-DROP
            # (DSM's silent default-deny — "deny" gets normalized to "none",
            # so "drop" is the real enforcement enum) with no allow rules
            # anywhere in the merged profile, we'd lock ourselves out. Refuse.
            # An allow rule anywhere (global OR per-adapter) is sufficient —
            # global rules apply across all interfaces.
            drop_adapters = [
                ad for ad in desired_adapters if (target.get(ad) or {}).get("policy") == "drop"
            ]
            if drop_adapters:
                allow_anywhere = any(
                    isinstance(r, dict) and r.get("policy") == "allow"
                    for ad in target
                    if ad != "name"
                    for r in (target[ad].get("rules") or [])
                )
                if not allow_anywhere:
                    print(
                        "FAIL anti-lockout: target has default-drop on %s "
                        "with no allow rules anywhere. Refusing to push "
                        "(would block SSH). Add at least one allow rule." % drop_adapters
                    )
                    return 1

            if a.check:
                print("WOULD-CHANGE " + json.dumps(sorted(drift.keys())))
                return 0

            s.profile_set(target, applying=False)
            if a.apply:
                s.profile_apply(a.profile_name)
                print("CHANGED " + json.dumps(sorted(drift.keys())))
            else:
                print("CHANGED-NO-APPLY " + json.dumps(sorted(drift.keys())))
            return 0
    except DSMError as e:
        print("FAIL %s" % str(e)[:200])
        return 1


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
        res = _exec(
            "SYNO.Core.Security.Firewall.Profile", "version=1", "method=get", "name=" + a.profile
        )
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

    pp = sub.add_parser(
        "probe-profile", help="Read-only: report whether the named firewall profile has any rules."
    )
    pp.add_argument("--profile", required=True)
    pp.set_defaults(func=do_probe_profile)

    fp = sub.add_parser(
        "firewall-profile",
        help="Push per-adapter rules to a DSM firewall profile via the "
        "HTTP webapi (Profile.set + Profile.Apply two-phase). "
        "Unmanaged adapters are preserved. Reads DSM_PASSWORD from env.",
    )
    fp.add_argument("--account", default="e4e-admin")
    fp.add_argument(
        "--password",
        default=None,
        help="DSM password. Falls back to DSM_PASSWORD env if "
        "omitted. Use `no_log: true` on the Ansible task.",
    )
    fp.add_argument("--profile-name", dest="profile_name", default="default")
    fp.add_argument(
        "--desired",
        required=True,
        help="JSON object: {adapter: {policy, rules: [...]}}. Only listed adapters are managed.",
    )
    fp.add_argument(
        "--apply",
        action="store_true",
        help="After Profile.set, also Profile.Apply (commit to "
        "live nftables). Without this, the profile is saved "
        "to disk but not activated.",
    )
    fp.add_argument("--check", action="store_true")
    fp.set_defaults(func=do_firewall_profile)

    pg = sub.add_parser(
        "probe-geoip",
        help="Read-only: surface DSM geoip-related state "
        "(countries listable, firewall enable/profile, "
        "per-adapter rule policies, count of geoip rules).",
    )
    pg.set_defaults(func=do_probe_geoip)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
