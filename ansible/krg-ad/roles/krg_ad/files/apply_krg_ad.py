#!/usr/bin/env python3
"""Converge KRG.LOCAL Active Directory structure to spec by wrapping samba-tool.

Runs ON the domain controller (krg-ldap) as root. Stdlib-only — the desired
state is parsed from YAML on the control node and handed in as a JSON --plan
file, so this script needs no PyYAML on the target (just samba-tool + python3).

Subcommands (one per spec concern):
  groups            create missing groups from groups.yml         (never deletes)
  service-accounts  ensure service accounts + their group membership (never removes)
  acls              ensure delegated ACE grants from acls.yml      (never removes)
  password-policy   converge domain password settings             (drift-only set)

NON-AUTHORITATIVE by design (ADR 0010): membership and ACEs are only ever ADDED.
Human group membership belongs to roster; an authoritative reconcile would delete
roster-set members. Drift (live objects absent from spec) is reported, not removed.

Output protocol (consumed by the ansible role's changed_when/failed_when):
  OK no-change | OK <detail>     — converged, nothing to do
  WOULD-CHANGE <detail>          — --check found drift (no mutation performed)
  CHANGED <detail>               — a mutation was applied
  FAIL <detail>                  — error / unsatisfiable (exit code 2)
Exit 0 unless any FAIL line was emitted (then 2).
"""

import argparse
import json
import os
import subprocess
import sys

SAMBA_TOOL = os.environ.get("SAMBA_TOOL", "samba-tool")

# Control-access-right GUIDs (well-known, stable across AD/Samba).
RIGHTS = {
    "reset-password": "00299570-246d-11d0-a768-00aa006e0529",
}

# SDDL ace inheritance flags.
INHERIT_FLAGS = {
    "this-object": "",
    "child-users": "CI",  # container-inherit: applies to descendant (user) objects
}

# password-policy: spec key -> (show-output label, samba-tool set flag, caster)
PWD_SETTINGS = {
    "min_pwd_length": ("Minimum password length", "--min-pwd-length", int),
    "max_pwd_age": ("Maximum password age (days)", "--max-pwd-age", int),
    "min_pwd_age": ("Minimum password age (days)", "--min-pwd-age", int),
    "history_length": ("Password history length", "--history-length", int),
    "complexity": ("Password complexity", "--complexity", str),
}


# ── thin, mockable samba-tool wrapper ──────────────────────────────────────────
def run(*args):
    """Run samba-tool with args; return (rc, stdout, stderr)."""
    proc = subprocess.run(
        [SAMBA_TOOL, *args],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


# ── pure helpers (unit-tested) ─────────────────────────────────────────────────
def parse_pwd_settings(text):
    """Parse `samba-tool domain passwordsettings show` into a normalized dict.

    Keys match PWD_SETTINGS; complexity stays a lowercase string, the rest ints.
    """
    label_to_key = {label: key for key, (label, _flag, _cast) in PWD_SETTINGS.items()}
    out = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        label, _, value = line.partition(":")
        key = label_to_key.get(label.strip())
        if key is None:
            continue
        value = value.strip()
        out[key] = value.lower() if key == "complexity" else int(value)
    return out


def pwd_policy_diff(desired, live):
    """Return [(key, live_value, desired_value)] for managed keys that differ."""
    diffs = []
    for key, want in desired.items():
        if key not in PWD_SETTINGS:
            continue
        cast = PWD_SETTINGS[key][2]
        want_c = str(want).lower() if cast is str else cast(want)
        have = live.get(key)
        if have != want_c:
            diffs.append((key, have, want_c))
    return diffs


def pwd_set_flags(diffs, desired):
    """Build the `samba-tool domain passwordsettings set` flag list for diffs."""
    flags = []
    for key, _have, _want in diffs:
        flag, cast = PWD_SETTINGS[key][1], PWD_SETTINGS[key][2]
        val = str(desired[key]).lower() if cast is str else str(cast(desired[key]))
        flags.append("{}={}".format(flag, val))
    return flags


def parse_name_list(text):
    """Parse one-per-line `samba-tool {group,user} list` output into a set."""
    return {ln.strip() for ln in text.splitlines() if ln.strip()}


def build_ace(inherit, right_guid, sid):
    """Construct an object ACE granting an extended right to a SID."""
    return "(OA;{};CR;{};;{})".format(INHERIT_FLAGS[inherit], right_guid, sid)


def ace_present(sddl, right_guid, sid):
    """True if any ACE in the SDDL grants right_guid to sid (inheritance-agnostic)."""
    guid = right_guid.lower()
    needle_sid = sid.lower()
    for chunk in sddl.replace("(", "\n(").split("\n"):
        c = chunk.lower()
        if c.startswith("(") and guid in c and needle_sid in c:
            return True
    return False


# ── output bookkeeping ─────────────────────────────────────────────────────────
class Report:
    def __init__(self):
        self.changed = False
        self.failed = False

    def ok(self, msg="no-change"):
        print("OK " + msg)

    def would(self, msg):
        self.changed = True
        print("WOULD-CHANGE " + msg)

    def changed_(self, msg):
        self.changed = True
        print("CHANGED " + msg)

    def fail(self, msg):
        self.failed = True
        print("FAIL " + msg)

    def exit(self):
        sys.exit(2 if self.failed else 0)


def load_plan(path):
    with open(path) as fh:
        return json.load(fh)


# ── subcommands ────────────────────────────────────────────────────────────────
def cmd_groups(plan, check, rep):
    container = plan.get("container", "CN=Users,DC=krg,DC=local")
    desired = [g for g in plan.get("groups", []) if not g.get("skip")]
    rc, out, err = run("group", "list")
    if rc != 0:
        rep.fail("group list failed: " + (err or out).strip())
        return
    live = parse_name_list(out)
    desired_names = {g["name"] for g in desired}

    for g in desired:
        name = g["name"]
        if name in live:
            continue
        extra = []
        if g.get("description"):
            extra.append("--description=" + g["description"])
        if container and not container.upper().startswith("CN=USERS,"):
            extra.append("--groupou=" + container)
        if check:
            rep.would("create group '{}'".format(name))
            continue
        rc, out, err = run("group", "add", name, *extra)
        if rc != 0:
            rep.fail("create group '{}': {}".format(name, (err or out).strip()))
        else:
            rep.changed_("created group '{}'".format(name))

    # Drift visibility only — never delete (non-authoritative).
    extras = sorted(n for n in live - desired_names if not _is_builtin(n))
    if extras:
        print(
            "OK drift: live non-builtin groups absent from spec (not removed): " + ", ".join(extras)
        )
    if not rep.changed and not rep.failed:
        rep.ok()


# Heuristic: well-known AD groups created by `domain provision`, never spec-managed.
_BUILTIN = {
    "Domain Admins",
    "Domain Users",
    "Domain Guests",
    "Domain Computers",
    "Domain Controllers",
    "Enterprise Admins",
    "Schema Admins",
    "Group Policy Creator Owners",
    "Read-only Domain Controllers",
    "Enterprise Read-only Domain Controllers",
    "DnsAdmins",
    "DnsUpdateProxy",
    "Cert Publishers",
    "RAS and IAS Servers",
    "Allowed RODC Password Replication Group",
    "Denied RODC Password Replication Group",
    "Protected Users",
    "Key Admins",
    "Enterprise Key Admins",
    "Cloneable Domain Controllers",
    "Storage Replica Administrators",
    # CN=Builtin\* (samba-tool group list prints these flat)
    "Administrators",
    "Users",
    "Guests",
    "Account Operators",
    "Server Operators",
    "Print Operators",
    "Backup Operators",
    "Replicator",
    "Remote Desktop Users",
    "Network Configuration Operators",
    "Performance Monitor Users",
    "Performance Log Users",
    "Distributed COM Users",
    "IIS_IUSRS",
    "Cryptographic Operators",
    "Event Log Readers",
    "Certificate Service DCOM Access",
    "Terminal Server License Servers",
    "Incoming Forest Trust Builders",
    "Windows Authorization Access Group",
    "Pre-Windows 2000 Compatible Access",
}


def _is_builtin(name):
    return name in _BUILTIN


def cmd_service_accounts(plan, check, rep):
    rc, out, err = run("user", "list")
    if rc != 0:
        rep.fail("user list failed: " + (err or out).strip())
        return
    live_users = parse_name_list(out)

    for acc in plan.get("accounts", []):
        name = acc["name"]
        if name not in live_users:
            # Never auto-create: the password is a secret (OpenBao).
            rep.fail(
                "service account '{}' is ABSENT — create it out-of-band and "
                "store its password in OpenBao (not auto-created)".format(name)
            )
            continue
        for group in acc.get("member_of", []):
            rc, out, err = run("group", "listmembers", group)
            if rc != 0:
                rep.fail("listmembers '{}': {}".format(group, (err or out).strip()))
                continue
            if name in parse_name_list(out):
                continue
            if check:
                rep.would("add '{}' to group '{}'".format(name, group))
                continue
            rc, out, err = run("group", "addmembers", group, name)
            if rc != 0:
                rep.fail("addmembers {} -> {}: {}".format(name, group, (err or out).strip()))
            else:
                rep.changed_("added '{}' to group '{}'".format(name, group))
    if not rep.changed and not rep.failed:
        rep.ok()


def _resolve_sid(name):
    """Resolve a sAMAccountName to its objectSid via user, then group show."""
    for kind in ("user", "group"):
        rc, out, _err = run(kind, "show", name, "--attributes=objectSid")
        if rc != 0:
            continue
        for line in out.splitlines():
            if line.strip().lower().startswith("objectsid:"):
                return line.partition(":")[2].strip()
    return None


def cmd_acls(plan, check, rep):
    for ace in plan.get("acls", []):
        dn, trustee = ace["objectdn"], ace["trustee"]
        right = ace["right"]
        inherit = ace.get("inherit", "child-users")
        guid = RIGHTS.get(right)
        if guid is None:
            rep.fail("unknown right '{}' (known: {})".format(right, ", ".join(RIGHTS)))
            continue
        if inherit not in INHERIT_FLAGS:
            rep.fail("unknown inherit '{}'".format(inherit))
            continue
        sid = _resolve_sid(trustee)
        if not sid:
            rep.fail("cannot resolve SID for trustee '{}'".format(trustee))
            continue
        rc, out, err = run("dsacl", "get", "--objectdn=" + dn)
        if rc != 0:
            rep.fail("dsacl get {}: {}".format(dn, (err or out).strip()))
            continue
        if ace_present(out, guid, sid):
            continue
        sddl = build_ace(inherit, guid, sid)
        if check:
            rep.would("grant {} '{}' on {} ({})".format(right, trustee, dn, sddl))
            continue
        rc, out, err = run("dsacl", "set", "--objectdn=" + dn, "--sddl=" + sddl)
        if rc != 0:
            rep.fail("dsacl set {} on {}: {}".format(right, dn, (err or out).strip()))
        else:
            rep.changed_("granted {} '{}' on {}".format(right, trustee, dn))
    if not rep.changed and not rep.failed:
        rep.ok()


def cmd_password_policy(plan, check, rep):
    rc, out, err = run("domain", "passwordsettings", "show")
    if rc != 0:
        rep.fail("passwordsettings show failed: " + (err or out).strip())
        return
    live = parse_pwd_settings(out)
    desired = {k: v for k, v in plan.items() if k in PWD_SETTINGS}
    diffs = pwd_policy_diff(desired, live)
    if not diffs:
        rep.ok("policy already converged")
        return
    detail = "; ".join("{}: {} -> {}".format(k, h, w) for k, h, w in diffs)
    if check:
        rep.would("passwordsettings " + detail)
        return
    rc, out, err = run("domain", "passwordsettings", "set", *pwd_set_flags(diffs, desired))
    if rc != 0:
        rep.fail("passwordsettings set: " + (err or out).strip())
    else:
        rep.changed_("passwordsettings " + detail)


HANDLERS = {
    "groups": cmd_groups,
    "service-accounts": cmd_service_accounts,
    "acls": cmd_acls,
    "password-policy": cmd_password_policy,
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("subcommand", choices=sorted(HANDLERS))
    ap.add_argument("--plan", required=True, help="JSON file of desired state for this concern")
    ap.add_argument("--check", action="store_true", help="dry run — report drift, mutate nothing")
    args = ap.parse_args(argv)

    rep = Report()
    HANDLERS[args.subcommand](load_plan(args.plan), args.check, rep)
    rep.exit()


if __name__ == "__main__":
    main()
