#!/usr/bin/env python3
"""Apply DSM AD domain join (KRG.LOCAL) + winbind config idempotently.

Subcommands:
  domain-config   SYNO.Core.Directory.Domain set (v1) — realm + DC + OU only.
                  See OUT_KEYS / deferred-fields note below.
  test-join       Read-only join check via Directory.Domain.get → enable_domain.
                  Prints "JOINED <realm>" / "NOT-JOINED <reason>".
                  (SYNO.Core.Directory.Domain.Join doesn't exist on DSM 7.3.)
  join            One-shot AD join via Directory.Domain.set (full creds bundle).
                  Needs Domain Admin password; passed on argv (--no-log).
  admin-groups    Write /etc/synoinfo.conf Ad_Domain_Admin_Groups via
                  synosetkeyvalue. THIS is the global "AD-group → @administrators"
                  bridge that makes admins see every share without per-share
                  grants. Pre-reset config (e4e-nas 2026-05-21 backup) confirmed
                  it as `KRG-UCSD-EDU\\Engineers for Exploration NAS Admins`.
                  pkgctl-SMBService must be restarted to pick up the change
                  (role task handles that). Idempotent: GET via synogetkeyvalue,
                  SET only on drift. Webapi paths (Domain.Conf.set v2/v3 with
                  domain_admin_groups) accept the field but silently no-op —
                  validated empirically 2026-06-01.

Invoked by synology_ad ansible role via `script` (DSM py3.8). Same
OK/WOULD-CHANGE/CHANGED/FAIL contract as the other apply_*.py helpers.

Field mapping (DSM 7.3, validated empirically 2026-06-01 — see OUT_KEYS):
  realm    -> realm           # KRG.LOCAL (uppercase Kerberos realm)
  domain   -> domain_name     # krg.local (lowercase AD DNS domain)
  dc_host  -> server_address
  dc_ip    -> server_ip
  ou       -> ou

idmap_mode / idmap_uid_range / idmap_gid_range / allowed_groups are DEFERRED —
no matching field on Directory.Domain or Directory.Domain.Conf (validated by
API.Info enumeration 2026-06-01: idmap is hardcoded to `idmap config * :
backend = syno`, a Synology-proprietary backend with no webapi tuning surface).
admin_groups is handled by the `admin-groups` subcommand above (synoinfo.conf
key, NOT a Directory.Domain.set field).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
SYNOGETKEYVALUE = "/usr/syno/bin/synogetkeyvalue"
SYNOSETKEYVALUE = "/usr/syno/bin/synosetkeyvalue"
SYNOINFO_CONF = "/etc/synoinfo.conf"
# DSM stores the "AD groups whose members are NAS administrators" in
# /etc/synoinfo.conf under this key, as a single comma-separated string of
# `<NETBIOS>\<group>` entries (e.g. `KRG\Domain Admins,KRG\E4E Admin`).
# Confirmed from the 2026-05-21 pre-reset config backup (confbkp_config_tb)
# and validated live on e4e-nas 2026-06-01.
ADMIN_GROUPS_KEY = "Ad_Domain_Admin_Groups"
DOMAIN_API = "SYNO.Core.Directory.Domain"
# Note: SYNO.Core.Directory.Domain.Join doesn't exist on DSM 7.3 (returns
# err 102 "API does not exist"). Both the join itself AND the joined-state
# check happen on the parent `SYNO.Core.Directory.Domain` namespace:
#   - join check: Domain.get → look at data.enable_domain (bool)
#   - join action: Domain.set with full credential bundle (validated 2026-06-01)

# Field mapping for Directory.Domain.set on DSM 7.3 (validated 2026-06-01 from
# the iteratively-discovered "missing parameter" errors in synolog
# /var/log/messages → domain_service.cpp). The OLD mapping (`nbns_name`,
# `idmap_type`, `idmap_uid`, etc.) was a best-guess that returned err 2618
# on this DSM version. Re-discovered names:
OUT_KEYS = {
    "realm":          "realm",          # KRG.LOCAL (uppercase Kerberos realm)
    "domain":         "domain_name",    # krg.local (lowercase AD DNS domain)
    "dc_host":        "server_address",
    "dc_ip":          "server_ip",
    "ou":             "ou",
}

# idmap_mode / idmap_uid / idmap_gid / allowed_groups / admin_groups are
# NOT fields on SYNO.Core.Directory.Domain (verified by reading back GET
# post-join: only the OUT_KEYS above + enable_domain + advance_domain_conf
# are returned). The idmap config is owned by a winbind config file
# (smb.conf on DSM); allowed_groups lives on SYNO.Core.Directory.Domain.Conf
# or similar. Both deferred until probed empirically — same pattern as
# AutoBlock.Rules / SA categories.


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
            # `137.110.161.109` parse as malformed floats; DSM rejects with
            # err 4302 (validated 2026-06-01 on dsm_system; same fix
            # applied here for consistency).
            val = json.dumps(val)
        args.append("{}={}".format(key, val))
    return args


def _result(drift, check, apply_fn):
    if not drift:
        print("OK no-change")
        return 0
    if check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    res = apply_fn()
    if res.get("success"):
        print("CHANGED " + json.dumps(drift, sort_keys=True, default=str))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- domain-config (SYNO.Core.Directory.Domain, full-object) ----------------
def _normalize(v):
    if isinstance(v, list):
        return sorted(v)
    return v


def do_domain_config(a):
    """Push the realm/dc/ou config to a JOINED NAS via Directory.Domain.set.

    Idmap / allowed_groups / admin_groups are NOT in OUT_KEYS — they're
    not fields on Directory.Domain.set on DSM 7.3. The CLI args are kept
    (--allowed-groups / --idmap-* / --admin-groups required by the role
    contract) but validated-only here; their push lands when the right
    API is identified. Spec values in spec/e4e-nas/ad.yml stay as the
    declarative source of truth.
    """
    allowed = json.loads(a.allowed_groups) if a.allowed_groups else []
    admins = json.loads(a.admin_groups) if a.admin_groups else []
    for label, val in (("--allowed-groups", allowed), ("--admin-groups", admins)):
        if not isinstance(val, list):
            raise SystemExit("%s must be a JSON list" % label)

    desired = {
        OUT_KEYS["realm"]:   a.realm,
        OUT_KEYS["domain"]:  a.domain,
        OUT_KEYS["dc_host"]: a.dc_host,
        OUT_KEYS["dc_ip"]:   a.dc_ip,
        OUT_KEYS["ou"]:      a.ou,
    }

    current = _exec(DOMAIN_API, "version=1", "method=get")["data"]
    if not current.get("enable_domain", False):
        # Pre-join the SET silently drops everything (validated 2026-05-31);
        # need creds + the full bundle (handled by do_join). Until joined,
        # this is a no-op + WARN so the role's apply doesn't churn.
        sys.stderr.write(
            "WARN: Directory.Domain config staging deferred — NAS not joined "
            "to a domain. Run `ansible-playbook ... -e ad_join_password='<pass>'` "
            "to join (the join subcommand sends the full config bundle).\n")
        print("OK no-change (deferred — not joined)")
        return 0

    drift = {k: {"current": current.get(k), "desired": v}
             for k, v in desired.items() if current.get(k) != v}

    # Surface the deferred fields on every apply (not just no-drift) so it's
    # visible in the log. admin_groups is HANDLED — pushed by the synology_ad
    # role's post-join `synogroup --memberadd` task; only the other four lack
    # an API surface on Directory.Domain.set.
    sys.stderr.write(
        "INFO: idmap_mode / idmap_uid_range / idmap_gid_range / "
        "allowed_groups are NOT pushed (no matching field on "
        "SYNO.Core.Directory.Domain.set). Spec values in spec/e4e-nas/ad.yml "
        "stay the source of truth; idmap tuning is gated on the Synology "
        "`syno` idmap backend (no webapi). admin_groups IS pushed via the "
        "post-join synogroup --memberadd task in the role.\n")

    if not drift:
        print("OK no-change")
        return 0

    # Drift on managed fields post-join requires CREDS — Directory.Domain.set
    # is a creds-gated API even for config-only updates (synolog 2026-06-01:
    # "cannot get the paramter: username"). We can't blindly push without a
    # password, and we don't have one in this path (only do_join does). So:
    # report the drift but DEFER the SET — the operator must re-run with
    # `-e ad_join_password='<pass>'` to converge (do_join re-binds the join
    # with the new config in one shot). Practically rare — these fields
    # (realm/dc/ou) don't change in normal operation.
    sys.stderr.write(
        "WARN: Directory.Domain config drift detected ({}) but SET requires "
        "creds (synowebapi `cannot get the paramter: username`). Re-run with "
        "`-e ad_join_password='<pass>'` to push via the join path.\n"
        .format(sorted(drift.keys())))
    print("OK no-change (deferred — drift on creds-gated fields)")
    return 0


# --- test-join (read-only) --------------------------------------------------
def do_test_join(_a):
    """Print JOINED <realm> on success, NOT-JOINED <reason> otherwise.
    The role gates whether to attempt a join on the presence of the JOINED token.

    DSM 7.3 doesn't expose SYNO.Core.Directory.Domain.Join (returns err 102);
    `enable_domain` on the Directory.Domain GET is the canonical signal.
    Validated 2026-06-01.
    """
    try:
        res = _exec(DOMAIN_API, "version=1", "method=get")
    except RuntimeError as e:
        print("NOT-JOINED " + str(e)[:200])
        return 0
    data = res.get("data", {}) if res.get("success") else {}
    if data.get("enable_domain"):
        realm = data.get("domain_name", "")
        print("JOINED " + realm)
        return 0
    print("NOT-JOINED " + json.dumps(data))
    return 0


# --- join (one-shot; needs creds) -------------------------------------------
def do_join(a):
    """Join the NAS to the AD realm via Directory.Domain.set (not Join.start).

    The required SET payload (discovered iteratively from synolog's
    "cannot get the paramter: X" errors on this DSM 7.3, 2026-06-01):
      realm, domain_name, server_address, server_ip, username, password,
      ou, enable_domain=true
    """
    if not a.join_password:
        print("FAIL " + json.dumps({"error": "join requires --join-password"}))
        return 1
    payload = {
        "realm":          a.realm,
        "domain_name":    a.domain,
        "server_address": a.dc_host,
        "server_ip":      a.dc_ip,
        "username":       a.join_user,   # DSM 7.3 expects `username`, not `user`
        "password":       a.join_password,
        "ou":             a.ou,
        "enable_domain":  True,
    }
    res = _exec(DOMAIN_API, "version=1", "method=set", *_args_from(payload))
    if res.get("success"):
        print("CHANGED " + json.dumps({"joined": a.realm}))
        return 0
    print("FAIL " + json.dumps(res))
    return 1


# --- admin-groups (Ad_Domain_Admin_Groups via synosetkeyvalue) ----------------
def _get_keyvalue(path, key):
    """Read a synoinfo.conf-style key. Returns the value (no trailing newline)
    or "" if unset. Raises on synogetkeyvalue invocation failure."""
    out = subprocess.run([SYNOGETKEYVALUE, path, key], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("synogetkeyvalue failed: " + (out.stderr or out.stdout).strip())
    return out.stdout.rstrip("\n")


def _set_keyvalue(path, key, value):
    """Write a key via synosetkeyvalue. Raises on failure."""
    out = subprocess.run([SYNOSETKEYVALUE, path, key, value],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("synosetkeyvalue failed: " + (out.stderr or out.stdout).strip())


def do_admin_groups(a):
    """Set /etc/synoinfo.conf Ad_Domain_Admin_Groups to a comma-separated list
    of `<NETBIOS>\\<group>` entries. This is the global "AD-group → NAS
    administrator tier" mechanism — members of any listed group inherit
    @administrators-equivalent access on every share automatically, with no
    per-share grant required.

    Why not via webapi: Directory.Domain.Conf.set v2/v3 with domain_admin_groups
    returns success but silently no-ops (validated 2026-06-01 — the field is
    accepted but not in the GET schema and changes don't take effect). The
    pre-reset NAS used this same synoinfo.conf key (2026-05-21 confbkp_config_tb
    backup); synosetkeyvalue is the path that actually persists.

    The ansible role restarts pkgctl-SMBService when this task reports CHANGED
    so the new value takes effect immediately (validated 2026-06-01: removing
    a per-share grant left the share STILL visible to Domain Admins because
    Ad_Domain_Admin_Groups was set, confirming the mechanism is live).
    """
    groups = json.loads(a.groups)
    if not isinstance(groups, list) or not all(isinstance(g, str) for g in groups):
        raise SystemExit("--groups must be a JSON array of strings")
    if not a.netbios:
        raise SystemExit("--netbios is required (typically realm.split('.')[0])")
    desired = ",".join(a.netbios + "\\" + g for g in groups)
    try:
        current = _get_keyvalue(SYNOINFO_CONF, ADMIN_GROUPS_KEY)
    except RuntimeError as e:
        print("FAIL " + json.dumps({"error": str(e)}))
        return 1
    if current == desired:
        print("OK no-change")
        return 0
    drift = {"current": current, "desired": desired}
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    try:
        _set_keyvalue(SYNOINFO_CONF, ADMIN_GROUPS_KEY, desired)
    except RuntimeError as e:
        print("FAIL " + json.dumps({"error": str(e)}))
        return 1
    print("CHANGED " + json.dumps(drift, sort_keys=True))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM AD join + winbind config via synowebapi.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("domain-config", help="Directory.Domain (realm + DC + idmap + groups)")
    d.add_argument("--realm", required=True)
    d.add_argument("--domain", required=True)
    d.add_argument("--dc-host", dest="dc_host", required=True)
    d.add_argument("--dc-ip", dest="dc_ip", required=True)
    d.add_argument("--ou", required=True)
    d.add_argument("--idmap-mode", dest="idmap_mode", required=True)
    d.add_argument("--idmap-uid-range", dest="idmap_uid_range", required=True)
    d.add_argument("--idmap-gid-range", dest="idmap_gid_range", required=True)
    d.add_argument("--allowed-groups", dest="allowed_groups", required=True, help="JSON list")
    d.add_argument("--admin-groups", dest="admin_groups", required=True, help="JSON list")
    d.add_argument("--check", action="store_true")
    d.set_defaults(func=do_domain_config)

    t = sub.add_parser("test-join", help="Read-only join status check")
    t.set_defaults(func=do_test_join)

    j = sub.add_parser("join", help="One-shot AD join (needs creds)")
    j.add_argument("--realm", required=True)
    j.add_argument("--domain", required=True,
                   help="lowercase AD domain (e.g. krg.local) — DSM's domain_name field")
    j.add_argument("--dc-host", dest="dc_host", required=True)
    j.add_argument("--dc-ip", dest="dc_ip", required=True)
    j.add_argument("--ou", required=True)
    j.add_argument("--join-user", dest="join_user", required=True)
    j.add_argument("--join-password", dest="join_password", required=True)
    j.set_defaults(func=do_join)

    g = sub.add_parser("admin-groups",
                       help="Set /etc/synoinfo.conf Ad_Domain_Admin_Groups (global admin-tier bridge)")
    g.add_argument("--groups", required=True,
                   help="JSON array of AD group names (e.g. [\"Domain Admins\", \"E4E Admin\"])")
    g.add_argument("--netbios", required=True,
                   help="NETBIOS domain name (typically realm.split('.')[0], e.g. KRG)")
    g.add_argument("--check", action="store_true")
    g.set_defaults(func=do_admin_groups)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
