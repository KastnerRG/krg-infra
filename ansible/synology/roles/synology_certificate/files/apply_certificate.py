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
                      NB: `is_default` only flags which cert NEW services
                      get — it does NOT migrate existing service bindings.
                      For that, use bind-services below.
  bind-services       Bind a cert to specific DSM services (DSM web, FTPS,
                      KMIP, etc.) — required to actually MIGRATE services
                      off the factory self-signed cert after first LE
                      issuance. Idempotent: skips bindings already on the
                      target cert; warns + skips bindings for services
                      DSM doesn't have installed.
  list                Read-only — dump certs in JSON form. Debug aid + the
                      drift-export hook reads it.

Invoked by the synology_certificate ansible role via the `script` module.
Prints OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

API field-name confidence (DSM 7.3 — wizard-captured on e4e-nas 2026-06-02,
field names match what DSM itself sends through Chrome DevTools network traces):
- `SYNO.Core.Certificate.CRT method=list` returns
    {"data": {"certificates": [{"id", "desc", "subject": {"common_name"},
     "is_default", "valid_till", "services": [{"service", "subscriber",
     "display_name", "isPkg", "owner"}]}]}}
- `SYNO.Core.Certificate.LetsEncrypt method=create version=1` accepts
  `desc + domain_name + email` (NOT `domain`, and NO `SAN_list`/`server`).
  Multi-domain (SAN) certs put ALL names in `domain_name` as a ';'-joined list,
  CN first: `domain_name="cn;san1;san2"` (wizard-captured 2026-06-04). DSM
  defaults to the LE prod server; no `server=` param is sent. We mirror the
  list into `desc` as a human-readable record of what was requested — but NOT
  as the drift signal: DSM's own renewal resets `desc`, so comparing it caused
  an unbounded re-issue loop (see do_letsencrypt_create). SAN drift is measured
  against the cert's real SANs, read from the PEM under CERT_ARCHIVE.
- `SYNO.Core.Certificate.CRT method=set version=1` takes `as_default=true +
  desc + id`. There is NO `method=set_default` on DSM 7.3 — the older string
  is from DSM-6 captures and returns "API not found" (102).
- `SYNO.Core.Certificate.Service method=set version=1` takes a `settings`
  JSON array of `{service: {display_name, isPkg, owner, service, subscriber},
  old_id, id}` entries — one per (service, subscriber) tuple being migrated.
  Used by bind-services to move existing bindings off the factory cert.
"""

import argparse
import json
import os
import re
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
    out = subprocess.run([WEBAPI, "--exec", "api=" + api, *params], capture_output=True, text=True)
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


def _find_by_domain(certs, domain, on_duplicate="newest"):
    """Return the cert dict for `domain`, or None.

    DSM CAN hold multiple certs with the same CN, and it is not an exotic
    state: DSM's own cron LE renewal mints a NEW cert object rather than
    updating in place, leaving the old one behind (and still bound to the
    services) until someone deletes it in the UI. Observed on e4e-nas
    2026-08-06: 0FndQu (default, 4 services, exp Sep 2) alongside 5oVauL
    (unbound, exp Nov 2).

    This used to raise, on the reasoning that silently picking one would mask
    the duplicate. The masking worry is right; the hard failure was not — it
    took the ENTIRE fleet deploy red (synology_certificate aborts the play, so
    every later role stops) over a benign, self-inflicted, and self-healing
    condition, and the only remedy on offer was a UI click, i.e. exactly the
    drift ADR 0001 forbids.

    So: resolve DETERMINISTICALLY instead of silently. `on_duplicate`:
      * "newest" (default) — keep the cert with the latest valid_till. That is
        the renewal, so converging onto it is also what we WANT: set_default
        and bind_services then move the bindings off the expiring cert. The
        extras are reported by the caller, never dropped on the floor.
      * "fail"            — the old behaviour, for a caller that would rather
                            stop than choose.

    Certs with an unparseable valid_till sort oldest, so a garbled date can
    never win the tie-break and silently become the keeper.

    Returns the keeper only; use `_find_by_domain_all` when the caller needs
    to report or act on the extras.
    """
    keeper, _extras = _find_by_domain_all(certs, domain, on_duplicate)
    return keeper


def _find_by_domain_all(certs, domain, on_duplicate="newest"):
    """(keeper, extras) for `domain`. See _find_by_domain for the policy."""
    matches = [c for c in certs if _domain_matches(c, domain)]
    if not matches:
        return None, []
    if len(matches) == 1:
        return matches[0], []

    ids = [c.get("id") for c in matches]
    if on_duplicate == "fail":
        raise RuntimeError(
            "multiple certs share common_name=%r (ids=%r) — clean up via DSM "
            "UI before re-applying" % (domain, ids)
        )

    # datetime.min is TZ-naive and cannot be compared against the TZ-aware
    # values _parse_valid_till returns, so use an explicitly UTC sentinel.
    oldest = datetime.min.replace(tzinfo=timezone.utc)
    ordered = sorted(matches, key=lambda c: _parse_valid_till(c.get("valid_till")) or oldest)
    keeper = ordered[-1]
    return keeper, ordered[:-1]


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


def _warn(payload):
    """Report a non-fatal condition on STDERR.

    tasks/main.yml drives changed_when/failed_when off substring matches against
    stdout ("CHANGED" / "WOULD-CHANGE" / "FAIL"), so anything printed there is
    load-bearing parser input.

    WRITING TO STDERR IS *NOT* AN ESCAPE HATCH FROM THAT. `ansible.builtin.script`
    runs over a pty, which MERGES stderr into stdout — this very function's output
    was captured in `stdout` (with \\r\\n line endings) in deploy run 31514953921.
    A stderr-only warning still reaches the string failed_when tests. So warning
    payloads must never contain the substrings FAIL or CHANGED; keep the reserved
    words out of keys, values and notes alike. (The same misconception shipped in
    apply_dsm_system.py and took a fleet deploy red — see its OUTPUT CONTRACT note.)
    """
    sys.stderr.write("WARN " + json.dumps(payload, sort_keys=True) + "\n")


def _resolve_domain(certs, domain, on_duplicate):
    """_find_by_domain, but the extras are REPORTED rather than discarded.

    Keeping the duplicate visible is the whole point — the previous hard
    failure existed to stop a duplicate being masked, and dropping to a silent
    pick would have traded a too-loud failure for a too-quiet one.
    """
    keeper, extras = _find_by_domain_all(certs, domain, on_duplicate)
    if extras:
        _warn(
            {
                "duplicate_common_name": domain,
                "kept": keeper.get("id"),
                "kept_valid_till": keeper.get("valid_till"),
                "superseded": [
                    {"id": c.get("id"), "valid_till": c.get("valid_till")} for c in extras
                ],
                "note": (
                    "DSM holds >1 cert with this CN (its cron LE renewal mints a "
                    "new object instead of updating in place). Converging onto the "
                    "newest; the superseded cert(s) are now unused once "
                    "bind-services runs and can be deleted in the DSM UI."
                ),
            }
        )
    return keeper


def _now_utc():
    """Wrapper for testability (monkeypatch in tests)."""
    return datetime.now(timezone.utc)


# DSM keeps each cert's PEM under /usr/syno/etc/certificate/_archive/<id>/.
# This is the only place a cert's real SAN list is observable: CRT.list returns
# id/desc/subject/valid_till but NOT the SANs.
CERT_ARCHIVE = "/usr/syno/etc/certificate/_archive"


def _cert_sans(cert_id):
    """Return the cert's DNS SANs as a lowercased set, or None if undeterminable.

    Reads the PEM DSM already stores on disk rather than trusting `desc` (see
    do_letsencrypt_create for why the `desc` marker is not a usable drift
    signal). Verified against e4e-nas 2026-08-11.

    None means "could not tell" — a missing PEM, no openssl, or a DSM layout
    change — and is deliberately distinct from an empty set so the caller can
    refuse to guess. A real LE cert always carries at least its CN as a SAN, so
    an empty parse is treated as a failed read, not as "no SANs".
    """
    if not cert_id:
        return None
    path = os.path.join(CERT_ARCHIVE, str(cert_id), "cert.pem")
    try:
        out = subprocess.run(
            ["openssl", "x509", "-in", path, "-noout", "-ext", "subjectAltName"],
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    if out.returncode != 0:
        return None
    # openssl prints: "X509v3 Subject Alternative Name:\n    DNS:a, DNS:b"
    names = {n.strip().lower() for n in re.findall(r"DNS:([^,\s]+)", out.stdout)}
    return names or None


# ---------------------------------------------------------------------------
# letsencrypt-create — idempotent issuance
# ---------------------------------------------------------------------------
def do_letsencrypt_create(a):
    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})

    try:
        existing = _resolve_domain(certs, a.domain, a.on_duplicate)
    except RuntimeError as e:
        return _fail({"reason": str(e), "domain": a.domain})

    sans = json.loads(a.sans_json or "[]")
    if not isinstance(sans, list) or not all(isinstance(s, str) for s in sans):
        return _fail({"reason": "--sans-json must be a JSON array of strings", "got": a.sans_json})

    # DSM encodes a multi-domain (SAN) LE cert as ONE semicolon-joined
    # `domain_name` with the CN first — there is no `SAN_list` param (captured
    # from the DSM 7.3 wizard POST: domain_name="cn;san1;san2"). We still write
    # that string into `desc`, as a human-readable record of what the role asked
    # for.
    #
    # `desc` USED TO BE the drift signal as well, because CRT.list doesn't
    # surface a cert's SANs. That was wrong, and expensively so. DSM's own LE
    # renewal mints a NEW cert object with `desc` reset to the plain domain, so
    # every renewed cert looked like SAN drift and the role re-issued on EVERY
    # run. That put 5 issuances for the same identifier set inside 168h — Let's
    # Encrypt's per-identifier-set rate limit (syno-letsencrypt error 104,
    # surfaced as webapi 5524) — and left the fleet deploy red and unable to
    # converge (run 31514953921). #516's converge-onto-newest compounded it: the
    # newest cert is always DSM's marker-less one, so drift could never clear.
    #
    # Drift is now measured against the cert's REAL SANs, read from the PEM on
    # disk. Verified on e4e-nas 2026-08-11 — the DSM-renewed default cert
    # carries DNS:e4e-nas.ucsd.edu, DNS:s3-admin.e4e.ucsd.edu, DNS:s3.e4e.ucsd.edu.
    # The SANs were never actually lost; only the marker was, and the marker was
    # the thing being compared.
    domain_list = ";".join([a.domain] + sans)
    desired_names = {n.strip().lower() for n in [a.domain] + sans}

    payload_base = {"domain": a.domain, "email": a.email, "sans": sans}

    if existing is not None:
        valid_till = _parse_valid_till(existing.get("valid_till", ""))
        buffer = timedelta(days=int(a.renewal_buffer_days))
        actual_names = _cert_sans(existing.get("id"))

        if actual_names is None:
            # Couldn't read the cert's SANs (PEM missing, no openssl, DSM layout
            # change). Do NOT guess — and specifically, do not guess "drifted".
            # The two wrong answers are not symmetric: a needless re-issue burns
            # a Let's Encrypt slot that takes 168h to come back and is exactly
            # what broke the deploy, while skipping the SAN check is inert,
            # announced in this warning, and still leaves the expiry-based
            # renewal below doing its job. Err toward the reversible failure.
            _warn(
                {
                    "san_check_skipped": "could not read SANs for cert %r" % existing.get("id"),
                    "note": (
                        "SAN drift not evaluated this run; expiry-based renewal is "
                        "unaffected. Check that %s/<id>/cert.pem exists and openssl "
                        "is on PATH." % CERT_ARCHIVE
                    ),
                }
            )

        if actual_names is not None and actual_names != desired_names:
            # SAN set genuinely differs from spec → re-issue.
            payload = dict(
                payload_base,
                reason="cert SAN set differs from spec",
                current_sans=sorted(actual_names),
                desired=domain_list,
            )
        elif valid_till is None:
            # Couldn't parse — defensive re-issue. Don't no-op on an
            # unknown-expiry cert; safer to push a fresh one.
            payload = dict(
                payload_base,
                reason="cert exists but valid_till unparseable",
                valid_till_raw=existing.get("valid_till"),
            )
        elif valid_till - _now_utc() > buffer:
            # SANs match AND plenty of life left — DSM's auto-renew handles it.
            return _emit("no-change", {}, a.check)
        else:
            payload = dict(
                payload_base,
                reason="cert exists but expiring within buffer",
                valid_till=valid_till.isoformat(),
                buffer_days=int(a.renewal_buffer_days),
            )
    else:
        payload = dict(payload_base, reason="no cert for domain")

    if a.check:
        return _emit("would-change", payload, True)

    # `desc` = `domain_name` = the semicolon-joined CN+SANs (see above). For a
    # single-domain cert (no sans) this is just the CN, unchanged from before.
    le_params = [
        "version=1",
        "method=create",
        "desc=" + json.dumps(domain_list),
        "domain_name=" + json.dumps(domain_list),
        "email=" + json.dumps(a.email),
    ]
    r = _exec(LE_API, *le_params)
    if not r.get("success"):
        return _fail({"reason": "%s.create failed" % LE_API, "response": r, "payload": payload})
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# set-default — bind a cert as DSM's default (by domain)
# ---------------------------------------------------------------------------
def do_set_default(a):
    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})

    try:
        existing = _resolve_domain(certs, a.domain, a.on_duplicate)
    except RuntimeError as e:
        return _fail({"reason": str(e), "domain": a.domain})

    if existing is None:
        # set-default can only act on certs that exist. Two cases:
        # - apply mode: the bring-up order is letsencrypt-create THEN
        #   set-default, so a missing cert is a real ordering bug → FAIL.
        # - check mode: `letsencrypt-create --check` deliberately DOES NOT
        #   issue, so on a fresh box the cert won't exist yet for the
        #   subsequent `set-default --check`. That's not a bug, it's the
        #   expected dry-run shape — report WOULD-CHANGE (the planned
        #   binding after the planned issuance).
        if a.check:
            return _emit(
                "would-change",
                {
                    "domain": a.domain,
                    "reason": "letsencrypt-create would issue the cert; set-default would then bind it",
                },
                True,
            )
        return _fail(
            {"reason": "no cert for domain — run letsencrypt-create first", "domain": a.domain}
        )

    if existing.get("is_default") is True:
        return _emit("no-change", {}, a.check)

    payload = {"domain": a.domain, "cert_id": existing.get("id")}
    if a.check:
        return _emit("would-change", payload, True)

    # Method+param shape captured from DSM 7.3 wizard's set-as-default
    # POST on e4e-nas 2026-06-02:
    #   api=SYNO.Core.Certificate.CRT method=set version=1
    #     as_default=true desc="<domain>" id="<cert_id>"
    # NOT `method=set_default` (returns 103) — DSM overloads `set` with
    # `as_default=true` for this operation. `desc` is the certificate's
    # display description (conventionally the domain); the wizard always
    # passes it alongside the id.
    r = _exec(
        CRT_API,
        "version=1",
        "method=set",
        "as_default=true",
        "desc=" + json.dumps(a.domain),
        "id=" + json.dumps(existing.get("id")),
    )
    if not r.get("success"):
        return _fail(
            {
                "reason": "%s.set (as_default=true) failed" % CRT_API,
                "response": r,
                "payload": payload,
            }
        )
    return _emit("changed", payload, False)


# ---------------------------------------------------------------------------
# bind-services — bind cert to specific DSM services (DSM web, FTPS, ...)
# ---------------------------------------------------------------------------
SERVICE_API = "SYNO.Core.Certificate.Service"


def do_bind_services(a):
    """Bind the cert identified by --domain to the (service, subscriber)
    tuples in --bindings-json. Idempotent: only POST entries where the
    current cert_id differs from the target cert.

    API shape captured from DSM 7.3 wizard's "Settings" dialog on e4e-nas
    2026-06-02 — SYNO.Core.Certificate.Service.set takes a `settings`
    JSON array of:
        {
          "service": {                  # nested OBJECT, not flat string
            "display_name": "...",
            "isPkg":      bool,
            "owner":      "...",
            "service":    "...",        # inner service id
            "subscriber": "..."
          },
          "old_id": "<current cert id>",
          "id":     "<desired cert id>"
        }
    The inner `service` object comes verbatim from each cert's
    `services:` array as returned by CRT.list — we read it back, find
    the current binding, and submit the diff."""
    bindings = json.loads(a.bindings_json)
    if not isinstance(bindings, list):
        return _fail({"reason": "--bindings-json must be a JSON array", "got": a.bindings_json})

    certs = _list_certs()
    if certs is None:
        return _fail({"reason": "%s.list failed (auth/api error)" % CRT_API})

    try:
        target = _resolve_domain(certs, a.domain, a.on_duplicate)
    except RuntimeError as e:
        return _fail({"reason": str(e), "domain": a.domain})
    if target is None:
        # bind-services can only act on a cert that exists. Same check-mode
        # vs apply-mode split as set-default.
        if a.check:
            return _emit(
                "would-change",
                {
                    "domain": a.domain,
                    "reason": "letsencrypt-create would issue the cert; bind-services would then bind it",
                },
                True,
            )
        return _fail(
            {"reason": "no cert for domain — run letsencrypt-create first", "domain": a.domain}
        )

    target_id = target["id"]

    # Index every (service, subscriber) tuple across ALL certs to
    # find the CURRENT cert + the full service descriptor object DSM
    # expects on the wire.
    current = {}  # (svc, sub) -> {"cert_id": ..., "service_obj": {...}}
    for cert in certs:
        for svc in cert.get("services") or []:
            key = (svc.get("service"), svc.get("subscriber"))
            current[key] = {"cert_id": cert.get("id"), "service_obj": svc}

    settings_to_set = []
    skipped_missing = []
    for b in bindings:
        if not isinstance(b, dict) or "service" not in b or "subscriber" not in b:
            return _fail(
                {"reason": "each binding must have `service` and `subscriber`", "binding": b}
            )
        key = (b["service"], b["subscriber"])
        cur = current.get(key)
        if cur is None:
            # Service isn't registered on any cert — DSM may not have it
            # installed / enabled. Warn + skip rather than fail.
            skipped_missing.append(b)
            sys.stderr.write(
                "WARN: service=%r subscriber=%r not present on any cert "
                "(DSM service not installed?) — skipping.\n" % (b["service"], b["subscriber"])
            )
            continue
        if cur["cert_id"] == target_id:
            continue  # already bound to target — no-op
        svc_obj = cur["service_obj"]
        # Trim to the keys the wizard sends, in the order it sends them.
        # (Extra keys like display_name_i18n / multiple_cert / user_setable
        # are derived; not required on the wire.)
        settings_to_set.append(
            {
                "service": {
                    "display_name": svc_obj.get("display_name", ""),
                    "isPkg": bool(svc_obj.get("isPkg", False)),
                    "owner": svc_obj.get("owner", ""),
                    "service": svc_obj["service"],
                    "subscriber": svc_obj["subscriber"],
                },
                "old_id": cur["cert_id"],
                "id": target_id,
            }
        )

    if not settings_to_set:
        # Everything's either already bound or missing-and-skipped. Either
        # is "no live change required."
        return _emit("no-change", {"skipped_missing": skipped_missing}, a.check)

    payload = {
        "domain": a.domain,
        "target_cert_id": target_id,
        "bindings_to_set": len(settings_to_set),
        "services": [s["service"]["service"] for s in settings_to_set],
        "skipped_missing": skipped_missing,
    }
    if a.check:
        return _emit("would-change", payload, True)

    r = _exec(SERVICE_API, "version=1", "method=set", "settings=" + json.dumps(settings_to_set))
    if not r.get("success"):
        return _fail({"reason": "%s.set failed" % SERVICE_API, "response": r, "payload": payload})
    payload["restart_httpd"] = r.get("data", {}).get("restart_httpd", False)
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
        trimmed.append(
            {
                "id": c.get("id"),
                "desc": c.get("desc", ""),
                "common_name": subj.get("common_name"),
                "is_default": bool(c.get("is_default", False)),
                "valid_till": c.get("valid_till", ""),
            }
        )
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
    le.add_argument(
        "--sans-json",
        default="[]",
        help='JSON array of SANs (e.g. \'["a.example","b.example"]\'); '
        "empty list = single-domain cert",
    )
    le.add_argument(
        "--renewal-buffer-days",
        required=True,
        help="Re-issue if cert expires within this many days, regardless of existence",
    )
    le.add_argument("--on-duplicate", choices=["newest", "fail"], default="newest")
    le.add_argument("--check", action="store_true")
    le.set_defaults(fn=do_letsencrypt_create)

    sd = sub.add_parser("set-default")
    sd.add_argument("--domain", required=True)
    sd.add_argument("--on-duplicate", choices=["newest", "fail"], default="newest")
    sd.add_argument("--check", action="store_true")
    sd.set_defaults(fn=do_set_default)

    bs = sub.add_parser("bind-services")
    bs.add_argument("--domain", required=True)
    bs.add_argument(
        "--bindings-json", required=True, help="JSON array of {service, subscriber} dicts"
    )
    bs.add_argument("--on-duplicate", choices=["newest", "fail"], default="newest")
    bs.add_argument("--check", action="store_true")
    bs.set_defaults(fn=do_bind_services)

    ls = sub.add_parser("list")
    ls.set_defaults(fn=do_list)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
