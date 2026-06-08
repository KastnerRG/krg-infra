#!/usr/bin/env python3
"""Apply DSM notification settings idempotently via synowebapi. Subcommands per channel
config (all full-object set; partial = err 2001):
  mail   — SYNO.Core.Notification.Mail.Conf v2 (enable_mail, sender, smtp_server/port/ssl,
           auth.user, subject_prefix). The Gmail OAuth token is a separate bootstrap (DSM
           UI), not in this helper. enable_oauth=true is set; the token is acquired
           interactively post-rebuild.
  sms    — SYNO.Core.Notification.SMS.Conf v2 (enable).
  push   — SYNO.Core.Notification.Push.Conf v1 (msn/skype/mobile toggles).
  cms    — SYNO.Core.Notification.CMS.Conf v2 (enable).

The nested smtp_auth / smtp_info objects on Mail.Conf are preserved via the GET → merge
→ SET pattern (managed flat fields are overlaid into the live object dict).
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


def _diff(current, desired):
    """Top-level field diff (nested objects compared as dicts)."""
    return {
        k: {"current": current.get(k), "desired": v}
        for k, v in desired.items()
        if current.get(k) != v
    }


def apply_full(api, version, desired, check):
    current = _exec(api, "version=%d" % version, "method=get")["data"]
    drift = _diff(current, desired)

    def apply():
        current.update(desired)
        return _exec(api, "version=%d" % version, "method=set", *_args_from(current))

    return _result(drift, check, apply)


def do_mail(a):
    desired = {}
    if a.enable is not None:
        desired["enable_mail"] = _bool(a.enable)
    if a.oauth is not None:
        desired["enable_oauth"] = _bool(a.oauth)
    if a.sender_mail is not None:
        desired["sender_mail"] = a.sender_mail
    if a.sender_name is not None:
        desired["sender_name"] = a.sender_name
    if a.subject_prefix is not None:
        desired["subject_prefix"] = a.subject_prefix
    if a.smtp_server is not None or a.smtp_port is not None or a.smtp_ssl is not None:
        # smtp_info is a nested dict on Mail.Conf — overlay just the keys we manage.
        # We re-read the current value before merging to preserve unmanaged sub-keys.
        cur = _exec("SYNO.Core.Notification.Mail.Conf", "version=2", "method=get")["data"]
        smtp = dict(cur.get("smtp_info") or {})
        if a.smtp_server is not None:
            smtp["server"] = a.smtp_server
        if a.smtp_port is not None:
            smtp["port"] = int(a.smtp_port)
        if a.smtp_ssl is not None:
            smtp["ssl"] = _bool(a.smtp_ssl)
        desired["smtp_info"] = smtp
    if a.auth_user is not None:
        cur = _exec("SYNO.Core.Notification.Mail.Conf", "version=2", "method=get")["data"]
        auth = dict(cur.get("smtp_auth") or {})
        auth["user"] = a.auth_user
        auth["enable"] = True
        desired["smtp_auth"] = auth
    return apply_full("SYNO.Core.Notification.Mail.Conf", 2, desired, a.check)


def do_sms(a):
    desired = {}
    if a.enable is not None:
        # DSM field is `enable_sms`, not `enable` (validated 2026-05-31:
        # SYNO.Core.Notification.SMS.Conf v=2 GET keys are {api_id,
        # enable_sms, msg_interval, phone_info, provider_name, sender, user}).
        # Using `enable` made the SET silently drop the field AND the diff
        # saw current=null vs desired=false every run → false-positive CHANGED.
        desired["enable_sms"] = _bool(a.enable)
    return apply_full("SYNO.Core.Notification.SMS.Conf", 2, desired, a.check)


def do_push(a):
    desired = {}
    if a.msn is not None:
        desired["msn_enable"] = _bool(a.msn)
    if a.skype is not None:
        desired["skype_enable"] = _bool(a.skype)
    if a.mobile is not None:
        desired["mobile_enable"] = _bool(a.mobile)
    return apply_full("SYNO.Core.Notification.Push.Conf", 1, desired, a.check)


def do_cms(a):
    desired = {}
    if a.enable is not None:
        # DSM field is `cms_enable`, not `enable` (validated 2026-05-31:
        # SYNO.Core.Notification.CMS.Conf v=2 GET keys are
        # {available_templates, cms_enable, join_dsm_cms, template_id}).
        # Same false-positive CHANGED bug pattern as SMS above.
        desired["cms_enable"] = _bool(a.enable)
    return apply_full("SYNO.Core.Notification.CMS.Conf", 2, desired, a.check)


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("mail")
    m.add_argument("--enable")
    m.add_argument("--oauth")
    m.add_argument("--sender-mail", dest="sender_mail")
    m.add_argument("--sender-name", dest="sender_name")
    m.add_argument("--subject-prefix", dest="subject_prefix")
    m.add_argument("--smtp-server", dest="smtp_server")
    m.add_argument("--smtp-port", dest="smtp_port")
    m.add_argument("--smtp-ssl", dest="smtp_ssl")
    m.add_argument("--auth-user", dest="auth_user")
    m.add_argument("--check", action="store_true")
    m.set_defaults(func=do_mail)

    s = sub.add_parser("sms")
    s.add_argument("--enable")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_sms)

    p = sub.add_parser("push")
    p.add_argument("--msn")
    p.add_argument("--skype")
    p.add_argument("--mobile")
    p.add_argument("--check", action="store_true")
    p.set_defaults(func=do_push)

    c = sub.add_parser("cms")
    c.add_argument("--enable")
    c.add_argument("--check", action="store_true")
    c.set_defaults(func=do_cms)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
