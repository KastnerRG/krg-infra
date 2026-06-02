#!/usr/bin/env python3
"""Manage DSM Let's Encrypt certificates idempotently via synowebapi.

Subcommands:
  letsencrypt-create  Issue (or re-issue) an LE cert for one domain. Probes
                      SYNO.Core.Certificate.CRT.list for a matching cert;
                      no-op if one exists with > `renewal_buffer_days` of
                      life left, re-issue otherwise. DSM has its own cron-
                      driven LE renewal — this subcommand is the safety
                      net + first-bring-up path, not the renewal driver.
  set-default         Set a cert (identified by its common-name domain)
                      as DSM's default. Idempotent: if the matching cert
                      already has is_default=true, no-op.
  list                Read-only — dump certs in JSON form. Debug aid + the
                      drift-export hook reads it.

Invoked by the synology_certificate ansible role via the `script` module.
Prints OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

API field-name confidence (DSM 7.3):
- `SYNO.Core.Certificate.CRT method=list` returns
    {"data": {"certificates": [{"id", "desc", "subject": {"common_name"},
     "is_default", "valid_till"}]}}
  Confirmed empirically on e4e-nas 2026-06-02.
- `SYNO.Core.Certificate.LetsEncrypt method=create` accepts:
    domain (str), email (str), SAN_list (JSON list), server ("prod"/"stg")
  Field names best-known from community DSM 7.x captures — expect a flip
  on first apply against a real box; same iteration pattern as the other
  synology_* role apply scripts.
- `SYNO.Core.Certificate.CRT method=set_default` takes the cert `id` as
  the SET parameter. ID is the 6-char short id from list output (e.g.
  "xPpc1W").
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone

WEBAPI = "/usr/syno/bin/synowebapi"

CRT_API = "SYNO.Core.Certificate.CRT"
LE_API = "SYNO.Core.Certificate.LetsEncrypt"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _exec(api, *params):
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params],
                         capture_output=True, text=True)
    txt = out.stdout
    brace = txt.find("{")
    if brace < 0:
        raise RuntimeError("no JSON in synowebapi output: " + (txt or out.stderr))
    return json.loads(txt[brace:])


def _list_certs():
    """Return list of cert dicts from SYNO.Core.Certificate.CRT.list. On a
    failed GET (auth timeout / API rename) returns None — caller handles
    the structured FAIL rather than letting KeyError surface."""
    r = _exec(CRT_API, "version=1", "method=list")
    if not r.get("success"):
        return None
    return r.get("data", {}).get("certificates", [])


def _domain_matches(cert, domain):
    """A cert MATCHES a target domain if its common-name == domain (the
    SAN list isn't surfaced by the .list API on DSM 7.3 — only the CN).
    If multi-SAN matching becomes needed, GET the cert detail to read SAN
    list; for now CN-only is sufficient for our single-domain LE certs."""
    subj = cert.get("subject", {}) or {}
    return subj.get("common_name") == domain


def _find_by_domain(certs, domain):
    """Return the cert dict for `domain`, or None. Refuses on ambiguity:
    DSM CAN hold multiple certs with the same CN (e.g. an old + new during
    a manual rotation), and silently picking one would mask the duplicate."""
    matches = [c for c in certs if _domain_matches(c, domain)]
    if len(matches) > 1:
        ids = [c.get("id") for c in matches]
        raise RuntimeError(
            "multiple certs share common_name=%r (ids=%r) — clean up via DSM "
            "UI before re-applying" % (domain, ids))
    return matches[0] if matches else None


def _parse_valid_till(s):
    """DSM's valid_till is RFC-2822-ish: 'May 31 04:05:39 2027 GMT'. Parse
    to a TZ-aware datetime (UTC). Returns None if unparseable so callers
    can treat as 'unknown → re-issue defensively'."""
    if not s:
        return None
    # Strip the timezone suffix; DSM always reports GMT/UTC. `%Z` parsing
    # is glibc-dependent + flaky, so explicit-strip is more portable.
    s = s.strip()
    if s.endswith(" GMT") or s.endswith(" UTC"):
        s = s[:-4]
    try:
        dt = datetime.strptime(s, "%b %d %H:%M:%S %Y")
        return dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _emit(state, payload, check):
    if state == "no-change":
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(payload, sort_keys=True))
        return 0
    print("CHANGED " + json.dumps(payload, sort_keys=True))
    return 0


def _fail(payload):
    print("FAIL " + json.dumps(payload))
    return 1


def _now_utc():
    """Wrapper for testability (monkeypatch in tests)."""
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# letsencrypt-create — idempotent issuance
# ---------------------------------------------------------------------------
def do_letsencrypt_create(a):
    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})

    try:
        existing = _find_by_domain(certs, a.domain)
    except RuntimeError as e:
        return _fail({"reason": str(e), "domain": a.domain})

    payload_base = {"domain": a.domain, "email": a.email,
                    "sans": json.loads(a.sans_json or "[]")}

    if existing is not None:
        valid_till = _parse_valid_till(existing.get("valid_till", ""))
        buffer = timedelta(days=int(a.renewal_buffer_days))
        if valid_till is None:
            # Couldn't parse — defensive re-issue. Don't no-op on an
            # unknown-expiry cert; safer to push a fresh one.
            payload = dict(payload_base, reason="cert exists but valid_till unparseable",
                           valid_till_raw=existing.get("valid_till"))
        elif valid_till - _now_utc() > buffer:
            # Plenty of life left — DSM's auto-renew will take care of it.
            return _emit("no-change", {}, a.check)
        else:
            payload = dict(payload_base, reason="cert exists but expiring within buffer",
                           valid_till=valid_till.isoformat(),
                           buffer_days=int(a.renewal_buffer_days))
    else:
        payload = dict(payload_base, reason="no cert for domain")

    if a.check:
        return _emit("would-change", payload, True)

    sans = json.loads(a.sans_json or "[]")
    if not isinstance(sans, list) or not all(isinstance(s, str) for s in sans):
        return _fail({"reason": "--sans-json must be a JSON array of strings",
                      "got": a.sans_json})

    r = _exec(
        LE_API, "version=1", "method=create",
        "domain=" + json.dumps(a.domain),
        "email=" + json.dumps(a.email),
        "SAN_list=" + json.dumps(sans),
        "server=" + json.dumps("prod"),
    )
    if not r.get("success"):
        return _fail({"reason": "%s.create failed" % LE_API,
                      "response": r, "payload": payload})
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# set-default — bind a cert as DSM's default (by domain)
# ---------------------------------------------------------------------------
def do_set_default(a):
    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})

    try:
        existing = _find_by_domain(certs, a.domain)
    except RuntimeError as e:
        return _fail({"reason": str(e), "domain": a.domain})

    if existing is None:
        # set-default can only act on certs that exist. Caller's bring-up
        # order is letsencrypt-create THEN set-default, so a missing cert
        # here is a real ordering bug — FAIL clean.
        return _fail({"reason": "no cert for domain — run letsencrypt-create first",
                      "domain": a.domain})

    if existing.get("is_default") is True:
        return _emit("no-change", {}, a.check)

    payload = {"domain": a.domain, "cert_id": existing.get("id")}
    if a.check:
        return _emit("would-change", payload, True)

    r = _exec(
        CRT_API, "version=1", "method=set_default",
        "id=" + json.dumps(existing.get("id")),
    )
    if not r.get("success"):
        return _fail({"reason": "%s.set_default failed" % CRT_API,
                      "response": r, "payload": payload})
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# list — read-only debug + drift-export hook
# ---------------------------------------------------------------------------
def do_list(a):
    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})
    # Trim to the stable fields we care about — keeps the diff
    # surface small for drift-export usage.
    trimmed = []
    for c in certs:
        subj = c.get("subject", {}) or {}
        trimmed.append({
            "id":          c.get("id"),
            "desc":        c.get("desc", ""),
            "common_name": subj.get("common_name"),
            "is_default":  bool(c.get("is_default", False)),
            "valid_till":  c.get("valid_till", ""),
        })
    print(json.dumps(trimmed, sort_keys=True, indent=2))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    le = sub.add_parser("letsencrypt-create")
    le.add_argument("--domain", required=True)
    le.add_argument("--email", required=True)
    le.add_argument("--sans-json", default="[]",
                    help='JSON array of SANs (e.g. \'["a.example","b.example"]\'); '
                         'empty list = single-domain cert')
    le.add_argument("--renewal-buffer-days", required=True,
                    help="Re-issue if cert expires within this many days, "
                         "regardless of existence")
    le.add_argument("--check", action="store_true")
    le.set_defaults(fn=do_letsencrypt_create)

    sd = sub.add_parser("set-default")
    sd.add_argument("--domain", required=True)
    sd.add_argument("--check", action="store_true")
    sd.set_defaults(fn=do_set_default)

    ls = sub.add_parser("list")
    ls.set_defaults(fn=do_list)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
