#!/usr/bin/env python3
"""Apply DSM web settings idempotently via synowebapi. Two subcommands:

  web          SYNO.Core.Web.DSM set (v2) — HSTS, HTTP/2 (SPDY), mDNS (avahi), SSDP,
               HTTPS redirect, ports, server-header. FULL-OBJECT pattern (partial = err
               2001), so GET → overlay managed keys → SET, only on drift.
  tls-profile  SYNO.Core.Web.Security.TLSProfile set (v1) — sets `default-level` (int).
               Maps the spec name (modern|intermediate|old) to DSM's integer. See note.

Invoked by the synology_dsm_web ansible role via the `script` module (runs on DSM's
Python 3.8 — same constraint as apply_smb/_nfs/_acls). Prints OK no-change /
WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>; the role keys changed/failed off that.

TLS integer mapping (DSM 7.3, community-best-known — empirical confirmation pending):
    modern=0, intermediate=1, old=2
The live capture on e4e-nas (2026-05-28) showed `default-level: 2`, plausibly Old.
If a rebuild apply shows the mapping flipped, flip TLS_LEVELS below and reapply —
single source of truth. The role also exposes `--level <int>` to override directly.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
DSM_API = "SYNO.Core.Web.DSM"
TLS_API = "SYNO.Core.Web.Security.TLSProfile"
TLS_LEVELS = {"modern": 0, "intermediate": 1, "old": 2}


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
    """dict -> synowebapi key=value tokens (bool->true/false, null skipped, list/dict->JSON)."""
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


# --- web (SYNO.Core.Web.DSM, full-object) -----------------------------------------
WEB_FIELDS = [
    # (flag-name-from-argparse, DSM field, value cast)
    ("hsts",           "enable_hsts",            _bool),
    ("avahi",          "enable_avahi",           _bool),
    ("ssdp",           "enable_ssdp",            _bool),
    ("http2",          "enable_spdy",            _bool),     # DSM calls HTTP/2 "SPDY"
    # `enable_https` is NOT a real field on SYNO.Core.Web.DSM (validated
    # 2026-05-31 against e4e-nas: GET keys don't include it, only
    # enable_https_redirect). HTTPS itself is implicit — DSM listens on
    # https_port unconditionally when https_port is set. Pushing
    # `enable_https` made the SET silently drop the field AND the GET-diff
    # see current=null vs desired=true every run → false-positive CHANGED.
    # ("https", "enable_https", _bool),  -- dropped
    ("https_redirect", "enable_https_redirect",  _bool),
    ("server_header",  "enable_server_header",   _bool),
    ("http_port",      "http_port",              int),
    ("https_port",     "https_port",             int),
]


def do_web(a):
    desired = {dsm: cast(v) for (flag, dsm, cast) in WEB_FIELDS
               if (v := getattr(a, flag, None)) is not None}
    current = _exec(DSM_API, "version=2", "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(DSM_API, "version=2", "method=set", *_args_from(current))

    return _result(drift, a.check, apply)


# --- tls-profile (SYNO.Core.Web.Security.TLSProfile) ------------------------------
def do_tls(a):
    if a.level is not None:
        level = int(a.level)
    elif a.profile is not None:
        try:
            level = TLS_LEVELS[a.profile.lower()]
        except KeyError:
            raise SystemExit("--profile must be one of: " + ", ".join(TLS_LEVELS))
    else:
        raise SystemExit("tls-profile: pass --profile or --level")

    cur = _exec(TLS_API, "version=1", "method=get")["data"]
    cur_level = cur.get("default-level")
    drift = ({} if cur_level == level
             else {"default-level": {"current": cur_level, "desired": level}})

    def apply():
        return _exec(TLS_API, "version=1", "method=set", "default-level=" + str(level))

    return _result(drift, a.check, apply)


def main(argv=None):
    # allow_abbrev=False so removing a field (e.g. --https in 2026-05-31 after
    # discovering it's not a real DSM field) doesn't let an unrelated abbrev-
    # match silently activate — argparse would otherwise match `--https` to
    # `--https-redirect` or `--https-port` and either silently consume the
    # next positional OR error "ambiguous option". Exact-match only.
    ap = argparse.ArgumentParser(description="Apply DSM web settings via synowebapi.",
                                 allow_abbrev=False)
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("web", help="DSM web config (HSTS / HTTP2 / mDNS / SSDP / ports)",
                       allow_abbrev=False)
    for flag, _dsm, _cast in WEB_FIELDS:
        w.add_argument("--" + flag.replace("_", "-"), dest=flag)
    w.add_argument("--check", action="store_true")
    w.set_defaults(func=do_web)

    t = sub.add_parser("tls-profile", help="TLS compatibility profile",
                       allow_abbrev=False)
    t.add_argument("--profile", help="modern|intermediate|old (mapped via TLS_LEVELS)")
    t.add_argument("--level", help="raw integer override (rebuild-time sanity-check)")
    t.add_argument("--check", action="store_true")
    t.set_defaults(func=do_tls)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
