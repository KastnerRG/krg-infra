#!/usr/bin/env python3
"""Apply DSM share-level ACL grants + optional recursive filesystem-ACL stamp.

Three subcommands:

  setuser           Apply the share -> principal grant matrix from
                    spec/e4e-nas/acls.yml. Each grant names a `group` (DSM needs
                    an `@` prefix — a bare group name silently no-ops!) or a `user`,
                    with `access: rw|ro|no` (-> DSM tiers RW/RO/NA). Reads current
                    tiers via `synoshare --list_acl`, diffs, and only re-sets tiers
                    that drift, using the `=` operator (sets each tier EXACTLY).
                    Validated on the DSM 7.3.2-86009 rig.

  admin-grants      Additively grant a set of @-prefixed principals (typically AD
                    admin groups like `@KRG\\Domain Admins`) to a tier on every
                    share in --shares. Uses the `+` operator — does NOT touch
                    other grants on the tier. Idempotent: GETs current state,
                    only `+`-adds entries that are MISSING. The bridge from
                    ad.yml `admin_groups` to share visibility without enumerating
                    every share in acls.yml. Independent of the `setuser` matrix.

  recursive-stamp   Runs `synoacltool -reset -R <path>` to re-apply the share-root
                    filesystem ACL down the entire subtree. This is the
                    "apply to this folder, sub-folders and files" pass from
                    runbook §4 — needed POST-AD-JOIN when preserved data carries
                    dead old-domain SIDs that won't resolve under KRG.LOCAL.
                    Intended to run with `--tags acls-recursive` (explicit), NOT
                    on every synology_base re-apply (it walks the whole tree).

Run by the synology_acls role via the `script` module (DSM's Python 3.8). Prints
OK no-change / WOULD-CHANGE <json> / CHANGED <json> / FAIL <msg>.
"""
import argparse
import json
import re
import subprocess
import sys

SYNOSHARE = "/usr/syno/sbin/synoshare"
SYNOACLTOOL = "/usr/syno/bin/synoacltool"
TIER = {"rw": "RW", "ro": "RO", "no": "NA"}


def _run(cmd_and_args):
    return subprocess.run(cmd_and_args, capture_output=True, text=True)


# --- setuser (share-level grants) ----------------------------------------------
def parse_list_acl(out):
    """Parse `synoshare --list_acl` output -> {RW,RO,NA: set(principals)} (@name = group)."""
    tiers = {}
    for t in ("RW", "RO", "NA"):
        match = re.search(r"ACL " + t + r" List\s*\.*\[(.*?)\]", out)
        items = match.group(1).split(",") if (match and match.group(1)) else []
        tiers[t] = {x for x in items if x}
    return tiers


def current_tiers(share):
    return parse_list_acl(_run([SYNOSHARE, "--list_acl", share]).stdout)


def desired_tiers(grants):
    tiers = {"RW": set(), "RO": set(), "NA": set()}
    for g in grants:
        if "group" in g:
            name = "@" + g["group"]
        elif "user" in g:
            name = g["user"]
        else:
            raise SystemExit("grant needs 'group' or 'user': " + json.dumps(g))
        tier = TIER.get(str(g.get("access", "")).lower())
        if not tier:
            raise SystemExit("grant 'access' must be rw|ro|no: " + json.dumps(g))
        tiers[tier].add(name)
    return tiers


def do_setuser(a):
    desired = desired_tiers(json.loads(a.grants))
    current = current_tiers(a.share)
    drift = {
        t: {"current": sorted(current[t]), "desired": sorted(desired[t])}
        for t in ("RW", "RO", "NA")
        if current[t] != desired[t]
    }
    if not drift:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(drift, sort_keys=True))
        return 0
    for t in drift:  # `=` sets the tier exactly; empty string clears it
        r = _run([SYNOSHARE, "--setuser", a.share, t, "=", ",".join(sorted(desired[t]))])
        if r.returncode != 0:
            print("FAIL setuser %s %s: %s" % (a.share, t, (r.stderr or r.stdout).strip()))
            return 1
    print("CHANGED " + json.dumps(drift, sort_keys=True))
    return 0


# --- admin-grants (additive AD-admin-groups bridge across many shares) ------------
def do_admin_grants(a):
    """Additively grant a set of @-prefixed principals to one tier across many
    shares. Independent of the `setuser` matrix in acls.yml — this is the
    bridge from ad.yml `admin_groups` to share access without enumerating
    every share+grant pair in acls.yml.

    Behaviour:
      * Reads each share's current ACL via `--list_acl`.
      * For each share, computes the SET-DIFFERENCE of (desired grants) -
        (current tier members) and only `+`-adds the missing entries.
      * Skips shares where every desired grant is already present (per-share
        no-op when converged; whole-task no-op when ALL shares are converged).
      * NEVER touches other tiers and NEVER removes principals already on the
        target tier — `+` is purely additive.

    Why this exists separately from setuser: the setuser matrix is authoritative
    per-share (a principal omitted there is REMOVED), so listing one share
    forces you to write the FULL grant list for it — including every project
    group and admin. admin-grants is for cross-cutting "all shares get this
    admin tier" rules; acls.yml stays free to add per-share project grants
    without re-asserting the admins on every entry.
    """
    desired = set(json.loads(a.grants))
    shares = json.loads(a.shares)
    tier = a.tier
    if tier not in TIER.values():
        print("FAIL " + json.dumps({"error": "--tier must be one of " + ",".join(sorted(TIER.values())),
                                    "got": tier}))
        return 1
    per_share = {}
    for share in shares:
        current = current_tiers(share).get(tier, set())
        missing = sorted(desired - current)
        if not missing:
            continue
        per_share[share] = missing
    if not per_share:
        print("OK no-change")
        return 0
    if a.check:
        print("WOULD-CHANGE " + json.dumps(per_share, sort_keys=True))
        return 0
    for share, missing in sorted(per_share.items()):
        r = _run([SYNOSHARE, "--setuser", share, tier, "+", ",".join(missing)])
        if r.returncode != 0:
            print("FAIL admin-grants %s: %s" % (share, (r.stderr or r.stdout).strip()[:300]))
            return 1
    print("CHANGED " + json.dumps(per_share, sort_keys=True))
    return 0


# --- recursive-stamp (runbook §4 "apply to this folder, sub-folders and files") ----
def do_recursive_stamp(a):
    """Reset every file/dir under <path> to inherit the share root's ACL.

    There is no cheap "is this already done?" probe — synoacltool -reset -R walks
    the tree unconditionally. This is why the role gates it behind --tags
    acls-recursive: don't run it on every synology_base re-apply.

    In --check mode we just confirm the path exists (the tree-walk itself is the
    expensive part; reporting estimated entry counts would require its own walk).
    """
    import os
    if not os.path.isdir(a.path):
        print("FAIL " + json.dumps({"error": "path is not a directory", "path": a.path}))
        return 1
    if a.check:
        print("WOULD-CHANGE " + json.dumps({"action": "synoacltool -reset -R",
                                            "share": a.share, "path": a.path}))
        return 0
    r = _run([SYNOACLTOOL, "-reset", "-R", a.path])
    if r.returncode != 0:
        print("FAIL recursive-stamp %s: %s" % (a.path, (r.stderr or r.stdout).strip()[:400]))
        return 1
    print("CHANGED " + json.dumps({"share": a.share, "path": a.path,
                                   "action": "synoacltool -reset -R"}))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM share ACLs (grants + optional recursive stamp).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("setuser", help="Share-level ACL grants (synoshare --setuser)")
    s.add_argument("--share", required=True)
    s.add_argument("--grants", required=True, help="JSON array of {group|user, access}")
    s.add_argument("--check", action="store_true")
    s.set_defaults(func=do_setuser)

    g = sub.add_parser("admin-grants",
                       help="Additively grant @-prefixed principals to a tier across N shares")
    g.add_argument("--shares", required=True, help="JSON array of share names")
    g.add_argument("--grants", required=True, help="JSON array of @-prefixed principals")
    g.add_argument("--tier", required=True, choices=list(TIER.values()),
                   help="RW | RO | NA")
    g.add_argument("--check", action="store_true")
    g.set_defaults(func=do_admin_grants)

    r = sub.add_parser("recursive-stamp",
                       help="Re-apply share-root ACL to entire subtree (runbook §4)")
    r.add_argument("--share", required=True)
    r.add_argument("--path", required=True, help="Share root path, e.g. /volume1/maya")
    r.add_argument("--check", action="store_true")
    r.set_defaults(func=do_recursive_stamp)

    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
