#!/usr/bin/env python3
"""Apply DSM External Access (QuickConnect / UPnP / DDNS) idempotently.

Three subcommands, all full-object (partial = err 2001), GET → overlay → SET on drift:

  quickconnect   SYNO.Core.QuickConnect            set v1
  upnp           SYNO.Core.Network.Router.UPnP     set v1
  ddns           SYNO.Core.ExternalAccess.DDNS     set v1

Invoked by the synology_external_access ansible role via `script` (DSM py3.8).

Field mapping (DSM 7.3 best-known — empirical confirmation pending; the captured
NAS had QuickConnect + UPnP on per runbook §3). Flip OUT_KEYS on first-apply drift:
  quickconnect.enable -> enabled    (QuickConnect)
  upnp.enable         -> enabled    (UPnP)
  ddns.enable         -> enabled    (DDNS)
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
QC_API = "SYNO.Core.QuickConnect"
UPNP_API = "SYNO.Core.Network.Router.UPnP"
DDNS_API = "SYNO.Core.ExternalAccess.DDNS"

OUT_KEYS = {
    "qc_enable":   "enabled",
    "upnp_enable": "enabled",
    "ddns_enable": "enabled",
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


# DSM error code 102 == "API does not exist" — surface is absent on this model
# (e.g. SOHO/SMB units lack the Router.UPnP API; DDNS API is gated on the user
# configuring DDNS via the wizard first). For toggle surfaces we treat this as
# "absence == disabled" and let _toggle short-circuit to OK no-change when the
# desired state IS disabled.
ERR_API_NOT_EXIST = 102


def _exec_get(api):
    """GET; returns (data_dict, None) on success or (None, err_code) on
    DSM-level failure. Raises RuntimeError only on protocol violations
    (no JSON / success-but-no-data — never normal).
    """
    resp = _exec(api, "version=1", "method=get")
    if not resp.get("success", False):
        err = (resp.get("error") or {})
        return None, err.get("code")
    if "data" not in resp:
        raise RuntimeError(
            "DSM API {} GET returned success but no `data` key: {}".format(
                api, json.dumps(resp)))
    return resp["data"], None


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


def _toggle(api, key, enable, check):
    """Common GET/diff/SET shape for the three single-toggle surfaces.

    Absence handling: DSM err 102 ("API does not exist", e.g. Router.UPnP on
    SOHO units / DDNS pre-wizard) means the surface isn't installed. If our
    DESIRED state is `disabled`, absence == desired (no-op). If desired is
    `enabled`, hard-fail — we can't enable a surface that isn't there.
    """
    desired_bool = _bool(enable)
    desired = {key: desired_bool}
    try:
        current, err_code = _exec_get(api)
    except RuntimeError as e:
        print("FAIL " + json.dumps({"error": str(e), "api": api}))
        return 1
    if err_code is not None:
        if err_code == ERR_API_NOT_EXIST and not desired_bool:
            print("OK no-change")
            return 0
        print("FAIL " + json.dumps({
            "error": "DSM GET failed", "api": api, "code": err_code,
            "note": ("desired=enabled but API is not present on this DSM model"
                     if err_code == ERR_API_NOT_EXIST and desired_bool else
                     "see DSM error code table"),
        }))
        return 1
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=1", "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_quickconnect(a):
    return _toggle(QC_API, OUT_KEYS["qc_enable"], a.enable, a.check)


def do_upnp(a):
    return _toggle(UPNP_API, OUT_KEYS["upnp_enable"], a.enable, a.check)


def do_ddns(a):
    return _toggle(DDNS_API, OUT_KEYS["ddns_enable"], a.enable, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM External Access (QC/UPnP/DDNS) via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("quickconnect", do_quickconnect),
                     ("upnp", do_upnp),
                     ("ddns", do_ddns)):
        p = sub.add_parser(name)
        p.add_argument("--enable", required=True)
        p.add_argument("--check", action="store_true")
        p.set_defaults(func=fn)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
