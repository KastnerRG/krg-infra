#!/usr/bin/env python3
"""Apply DSM SMB global settings idempotently via synowebapi.

DSM's `SYNO.Core.FileServ.SMB` *set* rejects a partial object (error code 2001), so
we GET the full settings object (API version 3), overlay only the keys this role
manages, and SET the whole thing back — and only when something actually differs, so
re-runs are no-ops. Validated on the DSM 7.3.2-86009 test rig.

Invoked by the synology_smb ansible role via the `script` module (which runs over
DSM's Python 3.8 — below ansible-core's >=3.9 *module* floor, but fine for a plain
script). Prints one of: `OK no-change` / `WOULD-CHANGE <drift-json>` (--check) /
`CHANGED <drift-json>` / `FAIL <json>`; the role keys changed/failed off that.

synowebapi lives in /usr/syno/bin (not on root's PATH) and emits a `[Line N] Exec
WebAPI: ...` preamble before its JSON, which we strip.
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
API = "SYNO.Core.FileServ.SMB"
PROTO = {"SMB1": 1, "SMB2": 2, "SMB3": 3}  # DSM integer encoding


def _exec(*params):
    """Run synowebapi and parse its JSON (skipping the preamble line)."""
    out = subprocess.run(
        [WEBAPI, "--exec", "api=" + API, *params],
        capture_output=True, text=True,
    )
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def get_settings():
    return _exec("version=3", "method=get")["data"]


def set_settings(data):
    args = ["version=3", "method=set"]
    for key, val in data.items():
        if val is None:  # DSM returns nulls (e.g. enable_adserver); never set them
            continue
        if isinstance(val, bool):
            val = "true" if val else "false"
        args.append("{}={}".format(key, val))
    return _exec(*args)


def _bool(s):
    return str(s).strip().lower() in ("1", "true", "yes", "on")


def desired_from_args(a):
    """Map the spec-derived CLI flags to the DSM field names/types (only those given)."""
    d = {}
    if a.min_protocol:
        d["smb_min_protocol"] = PROTO[a.min_protocol]
    if a.max_protocol:
        d["smb_max_protocol"] = PROTO[a.max_protocol]
    if a.enable is not None:
        d["enable_samba"] = _bool(a.enable)
    if a.server_signing is not None:
        d["enable_server_signing"] = 1 if _bool(a.server_signing) else 0
    if a.ntlmv1_auth is not None:
        d["enable_ntlmv1_auth"] = _bool(a.ntlmv1_auth)
    return d


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--min-protocol", choices=PROTO)
    ap.add_argument("--max-protocol", choices=PROTO)
    ap.add_argument("--enable")          # SMB service on/off
    ap.add_argument("--server-signing")  # require server signing
    ap.add_argument("--ntlmv1-auth")     # allow legacy NTLMv1
    ap.add_argument("--check", action="store_true", help="report drift, change nothing")
    a = ap.parse_args(argv)

    desired = desired_from_args(a)
    current = get_settings()
    drift = {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }

    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0

    current.update(desired)
    res = set_settings(current)
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


if __name__ == "__main__":
    sys.exit(main())
