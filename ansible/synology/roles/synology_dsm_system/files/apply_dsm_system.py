#!/usr/bin/env python3
"""Apply DSM system-level config idempotently via synowebapi.
Subcommand `network` covers SYNO.Core.Network v2 set (full-object): hostname,
gateway, DNS, dns_manual, etc. Static interface IP/netmask isn't a top-level field
on this API — it lives on SYNO.Core.Network.Ethernet (per-interface set v2); subcommand
`ethernet` is provided for completeness, but its set may require additional fields
beyond what's covered here; the live IP `132.239.17.124/16` is already correct, so
this typically no-ops.

NTP server is documented in dsm-system.yml but the SET path is uncertain on this DSM
(it might be SYNO.Core.System.Conf or a Region.NTP API not in the captured .libs);
subcommand `ntp` is reserved for when the API is confirmed.
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
        elif isinstance(val, str):
            # synowebapi --exec parses each `key=value` as JSON. Bare
            # strings like `132.239.17.1` are interpreted as malformed
            # floats (synowebapi truncates to `132.239` and SET returns
            # err 4302). JSON-quote so DSM gets the exact string back.
            # Validated 2026-06-01 against e4e-nas: without quoting,
            # `gateway=132.239.17.1` → SET payload had gateway:132.239
            # → 4302; with quoting, the SET lands cleanly.
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


def apply_full(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_network(a):
    desired = {}
    if a.hostname is not None:
        # DSM's SYNO.Core.Network field is `server_name`, not `hostname`.
        # Setting `hostname` is silently dropped on older DSM and outright
        # errors 4302 on DSM 7.3 (validated post-cable-swap 2026-05-31 —
        # GET returns `server_name`, SET rejects unknown fields).
        desired["server_name"] = a.hostname
    if a.gateway is not None:
        desired["gateway"] = a.gateway
    if a.dns_primary is not None:
        desired["dns_primary"] = a.dns_primary
    if a.dns_secondary is not None:
        desired["dns_secondary"] = a.dns_secondary
    if a.dns_manual is not None:
        desired["dns_manual"] = _bool(a.dns_manual)
    if a.ipv4_first is not None:
        desired["ipv4_first"] = _bool(a.ipv4_first)
    return apply_full("SYNO.Core.Network", 2, desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    n = sub.add_parser("network")
    n.add_argument("--hostname")
    n.add_argument("--gateway")
    n.add_argument("--dns-primary", dest="dns_primary")
    n.add_argument("--dns-secondary", dest="dns_secondary")
    n.add_argument("--dns-manual", dest="dns_manual")
    n.add_argument("--ipv4-first", dest="ipv4_first")
    n.add_argument("--check", action="store_true")
    n.set_defaults(func=do_network)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
