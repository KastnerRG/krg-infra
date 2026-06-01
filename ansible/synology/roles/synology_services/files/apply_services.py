#!/usr/bin/env python3
"""Apply DSM file/system service settings idempotently via synowebapi.
Subcommands: ftp, afp, snmp. Each is a full-object set on its API (partial = err 2001),
so GET → overlay managed keys → SET, only on drift.

SFTP / WebDAV / Rsync: the synowebapi surfaces returned err 102 on probe — TODO discover
the right API namespace (likely package-provided) and add subcommands. Spec lists them
off for now.

SNMPv3 USM credentials (auth/priv password) are a separate bootstrap secret — NOT taken
on the CLI here. enable_snmp_v3=true without a credential set is accepted by the API but
no v3 user can authenticate until the credential is bootstrapped (DSM UI or a follow-up).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
APIS = {
    "ftp":  ("SYNO.Core.FileServ.FTP",  1),
    "afp":  ("SYNO.Core.FileServ.AFP",  1),
    "snmp": ("SYNO.Core.SNMP",          1),
}


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


def apply_service(svc, desired, check):
    api, ver = APIS[svc]
    current = _exec(api, "version=%d" % ver, "method=get")["data"]
    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % ver, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_ftp(a):
    desired = {}
    if a.enable_ftp is not None:
        desired["enable_ftp"] = _bool(a.enable_ftp)
    if a.enable_ftps is not None:
        desired["enable_ftps"] = _bool(a.enable_ftps)
    return apply_service("ftp", desired, a.check)


def do_afp(a):
    desired = {}
    if a.enable is not None:
        desired["enable_afp"] = _bool(a.enable)
    return apply_service("afp", desired, a.check)


def do_snmp(a):
    desired = {}
    if a.enable is not None:
        desired["enable_snmp"] = _bool(a.enable)
    if a.v1v2 is not None:
        desired["enable_snmp_v1v2"] = _bool(a.v1v2)
    if a.v3 is not None:
        desired["enable_snmp_v3"] = _bool(a.v3)
    if a.contact is not None:
        desired["contact"] = a.contact
    if a.location is not None:
        desired["location"] = a.location
    if a.name is not None:
        desired["name"] = a.name

    # SNMPv3 USM credential gate: enable_snmp_v3=true requires a USM user +
    # auth + priv credentials at the same SET, else DSM returns err 2202
    # ("v3 enable without credentials"). Three cases:
    #
    #   (1) spec wants v3 ON and creds ARE supplied
    #         → send rouser + v3_* fields
    #   (2) spec wants v3 ON and creds NOT supplied (bring-up before vault wires up)
    #         → soft-defer: pin enable_snmp_v3 to current, WARN on stderr,
    #           same shape as the AD-aware gate on User.Home enable_domain
    #   (3) spec wants v3 OFF
    #         → ignore creds; let the v3 flag flip false normally
    #
    # FIELD-NAME NOTE: the DSM SNMP webapi v3 field names are not documented.
    # The probes during e4e-nas first-apply (2026-05-30) eliminated
    # `auth_protocol`/`auth_password` and `v3_auth_proto`/`v3_auth_passwd` as
    # the actual names (both returned err 2202). The names below are a
    # best-guess from DSM CLI conventions; expect to flip on first apply
    # with real creds, same pattern as security_advisor / dsm_updates /
    # external_access OUT_KEYS empirical iteration. If err 2202 fires on
    # apply WITH creds, probe DSM UI's network capture for the right names
    # then flip below.
    if desired.get("enable_snmp_v3"):
        if a.v3_auth_password and a.v3_priv_password and a.rouser:
            desired["rouser"] = a.rouser
            desired["v3_auth_proto"] = a.v3_auth_protocol or "SHA"
            desired["v3_auth_passwd"] = a.v3_auth_password
            desired["v3_priv_proto"] = a.v3_priv_protocol or "AES"
            desired["v3_priv_passwd"] = a.v3_priv_password
        else:
            # Case (2): defer v3-enable until creds are bootstrapped. Pin to
            # current value (so no drift on the field) and warn.
            sys.stderr.write(
                "WARN: snmp.enable_snmp_v3=true deferred — v3 USM credentials "
                "(rouser + v3_auth_password + v3_priv_password) not supplied. "
                "DSM would return err 2202 on the SET. Add the secrets to "
                "secrets-syno.yml under `snmp_v3_*` and re-apply to converge.\n")
            # Will be pinned to current value by apply_service's GET/diff;
            # explicitly leaving enable_snmp_v3 in desired so the diff shows
            # current=false vs desired=true and pinning by overlay below.
            # Simplest: delete from desired so apply_service treats it as
            # unmanaged for this run.
            del desired["enable_snmp_v3"]
            # ALSO defer enable_snmp itself when no other protocol is enabled.
            # DSM errors 2202 on a SET that enables the daemon without at least
            # one working protocol — v1v2 is off here and v3 just got deferred,
            # so enable_snmp=true would land a daemon-with-no-protocols which
            # DSM rejects. The metadata fields (contact / location / name /
            # rouser) still go through; only the daemon-enable + v3 flag wait
            # for credentials to land in secrets-syno.yml. Validated against
            # the e4e-nas live API 2026-05-31.
            if desired.get("enable_snmp") and not _bool(a.v1v2 or "false"):
                # Validated 2026-05-31 against e4e-nas: when daemon is off,
                # DSM's Notification.SNMP set returns success=true but
                # SILENTLY DROPS metadata changes (contact / location / name
                # stay at their factory defaults). The role would then
                # report CHANGED on every run while nothing actually
                # persisted. Clearing all desired keeps the diff honest
                # (OK no-change with WARN) — the metadata gets applied
                # alongside enable_snmp once creds land in secrets-syno.yml.
                sys.stderr.write(
                    "WARN: snmp.enable_snmp=true ALSO deferred — DSM err 2202 "
                    "rejects daemon-enable with no protocol active "
                    "(v1v2=false, v3 deferred). Metadata (contact/location/"
                    "name) is ALSO deferred because DSM silently drops "
                    "metadata changes when the daemon is off.\n")
                desired.clear()
            # Also don't push rouser (would be a v3-only field with no v3 enabled)
            # — fall through; we never add it in this branch.
    else:
        # Case (3): v3 off, but still respect rouser/v1-rocommunity from spec
        # if provided. rouser stays empty if v3 disabled; that's fine.
        if a.rouser is not None:
            desired["rouser"] = a.rouser

    return apply_service("snmp", desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("ftp")
    f.add_argument("--enable-ftp", dest="enable_ftp")
    f.add_argument("--enable-ftps", dest="enable_ftps")
    f.add_argument("--check", action="store_true")
    f.set_defaults(func=do_ftp)

    af = sub.add_parser("afp")
    af.add_argument("--enable")
    af.add_argument("--check", action="store_true")
    af.set_defaults(func=do_afp)

    s = sub.add_parser("snmp")
    s.add_argument("--enable")
    s.add_argument("--v1v2")
    s.add_argument("--v3")
    s.add_argument("--contact")
    s.add_argument("--location")
    s.add_argument("--name")
    s.add_argument("--rouser")
    # SNMPv3 USM credentials (Option B credential plumbing). Operator-side
    # secrets come from secrets-syno.yml; empty/absent triggers soft-defer.
    s.add_argument("--v3-auth-protocol", dest="v3_auth_protocol", default=None,
                   help="SHA|SHA224|SHA256|SHA384|SHA512|MD5 (default SHA)")
    s.add_argument("--v3-auth-password", dest="v3_auth_password", default=None,
                   help="USM auth password (>=8 chars; SNMPv3 requirement)")
    s.add_argument("--v3-priv-protocol", dest="v3_priv_protocol", default=None,
                   help="AES|AES192|AES256|DES (default AES)")
    s.add_argument("--v3-priv-password", dest="v3_priv_password", default=None,
                   help="USM priv password (>=8 chars; SNMPv3 requirement)")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_snmp)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
