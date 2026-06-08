#!/usr/bin/env python3
"""krg drift detector — diff the LIVE Synology (e4e-nas) state against spec/e4e-nas/.

Git is the source of truth; any UI change is drift (ADR 0001). The synology_* role
exporters (`ansible-playbook ansible/synology/playbook.yml --tags export`) write per-host
live-state snapshots to a directory; this tool diffs those snapshots against the spec
and (a) prints a report and (b) emits Prometheus textfile-collector metrics for alerting.
It reads only files — no NAS access of its own — so it runs anywhere (e.g. krg-deploy on
a systemd timer, feeding node_exporter's textfile collector → the krg-prod Prometheus).

Resources: shares (presence), SMB globals, NFS (global + per-share rules), share ACLs.
Each diff mirrors the field mapping of the matching synology_* apply helper.

  drift_detector.py --spec-dir spec/e4e-nas \
      --snapshot-dir /var/lib/krg-deploy/synology-export --host e4e-nas \
      [--metrics-file e4e-nas-drift.prom] [--format text|json]

Exit: 0 = no drift, 1 = drift detected, 2 = error (missing/unparseable snapshot or spec).
"""

import argparse
import json
import os
import re
import sys
import time

import yaml

PROTO = {"SMB1": 1, "SMB2": 2, "SMB3": 3}  # mirrors apply_smb/apply_nfs

# Shares DSM/packages auto-create; never hand-managed, so not "extra" drift (shares.yml).
AUTO_SHARES = {
    "homes",
    "home",
    "NetBackup",
    "photo",
    "web",
    "surveillance",
    "ActiveBackupforBusiness",
}


# --- raw DSM output parsers (formats validated on the DSM 7.3 rig) --------------
def webapi_data(lines):
    """synowebapi JSON -> data{}. DSM pretty-prints the object's `{` on its own line; start
    there (robust whether or not the `[Line N] Exec WebAPI: ... param={} ...` preamble — which
    itself contains a `{` — leaked onto stdout)."""
    start = next((i for i, ln in enumerate(lines) if ln.lstrip().startswith("{")), None)
    if start is None:
        raise ValueError("no JSON object in synowebapi output")
    return json.loads("\n".join(lines[start:]))["data"]


def parse_enum(lines):
    """`synoshare --enum`/`synogroup --enum` -> [names] (names follow the 'N Listed:' line)."""
    names, seen = [], False
    for ln in lines:
        s = ln.strip()
        if not seen:
            if s.endswith("Listed:"):
                seen = True
            continue
        if s:
            names.append(s)
    return names


def parse_list_acl(text):
    """`synoshare --list_acl` -> {RW,RO,NA: set(principals)} (@name = group). Mirrors apply_acls."""
    tiers = {}
    for t in ("RW", "RO", "NA"):
        m = re.search(r"ACL " + t + r" List\s*\.*\[(.*?)\]", text)
        items = m.group(1).split(",") if (m and m.group(1)) else []
        tiers[t] = {x for x in items if x}
    return tiers


def desired_tiers(grants):
    """acls.yml grants -> {RW,RO,NA: set}. Mirrors apply_acls.desired_tiers."""
    tiers = {"RW": set(), "RO": set(), "NA": set()}
    tier = {"rw": "RW", "ro": "RO", "no": "NA"}
    for g in grants:
        name = "@" + g["group"] if "group" in g else g["user"]
        tiers[tier[str(g["access"]).lower()]].add(name)
    return tiers


def _norm_rules(rules):
    return json.dumps(sorted(rules, key=lambda r: r.get("client", "")), sort_keys=True)


def D(resource, key, desired, live):
    return {"resource": resource, "key": key, "desired": desired, "live": live}


# --- per-resource diffs ---------------------------------------------------------
def diff_shares(spec, snap):
    desired = {s["name"] for s in spec.get("shares", [])}
    live = set(parse_enum(snap.get("shares_raw", [])))
    out = [D("shares", n, "present", "absent") for n in sorted(desired - live)]
    out += [
        D("shares", n, "absent (unmanaged)", "present")
        for n in sorted(live - desired - AUTO_SHARES)
    ]
    return out


def diff_smb(spec, snap):
    s = spec.get("smb", {})
    desired = {
        "enable_samba": bool(s.get("enable", True)),
        "smb_min_protocol": PROTO[s.get("min_protocol", "SMB2")],
        "smb_max_protocol": PROTO[s.get("max_protocol", "SMB3")],
        "enable_server_signing": 1 if s.get("server_signing", True) else 0,
        "enable_ntlmv1_auth": bool(s.get("ntlmv1_auth", False)),
    }
    live = webapi_data(snap.get("smb_raw", []))
    return [D("smb", k, v, live.get(k)) for k, v in desired.items() if live.get(k) != v]


def diff_nfs(spec, snap):
    out = []
    n = spec.get("nfs", {})
    gdesired = {
        "enable_nfs": bool(n.get("enable", True)),
        "enable_nfs_v4": bool(n.get("nfsv4", True)),
        "nfs_v4_domain": n.get("v4_domain", ""),
    }
    glive = webapi_data(snap.get("nfs_global_raw", []))
    out += [
        D("nfs", "global." + k, v, glive.get(k)) for k, v in gdesired.items() if glive.get(k) != v
    ]

    live_rules = {r["share"]: webapi_data(r["load"])["rule"] for r in snap.get("nfs_rules_raw", [])}
    for exp in spec.get("exports", []):
        share = exp["share"]
        desired, live = exp.get("rules", []), live_rules.get(share, [])
        if _norm_rules(desired) != _norm_rules(live):
            out.append(D("nfs", "rules." + share, desired, live))
    return out


def diff_acls(spec, snap):
    out = []
    live_by_share = {
        a["share"]: parse_list_acl("\n".join(a["list_acl"])) for a in snap.get("share_acls", [])
    }
    for entry in spec.get("acls", []) or []:
        share = entry["share"]
        des = desired_tiers(entry.get("grants", []))
        live = live_by_share.get(share, {"RW": set(), "RO": set(), "NA": set()})
        for t in ("RW", "RO", "NA"):
            if des[t] != live[t]:
                out.append(D("acls", "%s.%s" % (share, t), sorted(des[t]), sorted(live[t])))
    return out


# resource -> (spec filename, snapshot suffix, diff fn, "does the spec have anything to check?")
RESOURCES = [
    ("shares", "shares.yml", "shares", diff_shares, lambda sp: bool(sp.get("shares"))),
    ("smb", "smb-globals.yml", "smb", diff_smb, lambda sp: bool(sp.get("smb"))),
    (
        "nfs",
        "nfs-exports.yml",
        "nfs",
        diff_nfs,
        lambda sp: bool(sp.get("nfs") or sp.get("exports")),
    ),
    ("acls", "acls.yml", "acls", diff_acls, lambda sp: bool(sp.get("acls"))),
]


def _load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def run(spec_dir, snapshot_dir, host):
    """Return (results, drifts) where results[resource] in {ok, drift, no-snapshot, error}."""
    results, drifts = {}, []
    for name, spec_file, suffix, diff_fn, has_work in RESOURCES:
        spec_path = os.path.join(spec_dir, spec_file)
        snap_path = os.path.join(snapshot_dir, "%s-%s.yml" % (host, suffix))
        try:
            spec = _load_yaml(spec_path)
        except (OSError, yaml.YAMLError) as e:
            results[name] = "error: spec %s" % e
            continue
        if not has_work(spec):
            results[name] = "ok"  # nothing in spec to enforce yet
            continue
        if not os.path.exists(snap_path):
            results[name] = "no-snapshot"
            continue
        try:
            found = diff_fn(spec, _load_yaml(snap_path))
        except (OSError, yaml.YAMLError, ValueError, KeyError) as e:
            results[name] = "error: %s" % e
            continue
        drifts += found
        results[name] = "drift" if found else "ok"
    return results, drifts


# --- output ---------------------------------------------------------------------
def render_text(host, results, drifts):
    lines = ["drift report for %s" % host, "=" * (16 + len(host))]
    for name, _f, _s, _d, _w in RESOURCES:
        n = sum(1 for d in drifts if d["resource"] == name)
        lines.append("  %-8s %s%s" % (name, results[name], " (%d)" % n if n else ""))
    if drifts:
        lines.append("\ndrift detail (desired vs live):")
        for d in drifts:
            lines.append(
                "  [%s] %s: spec=%s live=%s" % (d["resource"], d["key"], d["desired"], d["live"])
            )
    else:
        lines.append("\nno drift.")
    return "\n".join(lines)


def render_prometheus(host, results, drifts):
    def lbl(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    ok = all(not str(v).startswith("error") and v != "no-snapshot" for v in results.values())
    out = [
        "# HELP krg_synology_drift Live DSM state diverges from spec (1=drift).",
        "# TYPE krg_synology_drift gauge",
    ]
    for name, _f, _s, _d, _w in RESOURCES:
        n = sum(1 for d in drifts if d["resource"] == name)
        out.append(
            'krg_synology_drift{host="%s",resource="%s"} %d' % (lbl(host), name, 1 if n else 0)
        )
        out.append('krg_synology_drift_items{host="%s",resource="%s"} %d' % (lbl(host), name, n))
    out += [
        "# HELP krg_synology_drift_check_success Detector ran with all snapshots present+parsed.",
        "# TYPE krg_synology_drift_check_success gauge",
        'krg_synology_drift_check_success{host="%s"} %d' % (lbl(host), 1 if ok else 0),
        "# HELP krg_synology_drift_check_timestamp_seconds Unix time of this check.",
        "# TYPE krg_synology_drift_check_timestamp_seconds gauge",
        'krg_synology_drift_check_timestamp_seconds{host="%s"} %d' % (lbl(host), int(time.time())),
    ]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Diff live Synology state (exporter snapshots) vs spec."
    )
    ap.add_argument("--spec-dir", default="spec/e4e-nas")
    ap.add_argument("--snapshot-dir", required=True)
    ap.add_argument("--host", required=True)
    ap.add_argument("--metrics-file", help="write Prometheus textfile metrics here")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    a = ap.parse_args(argv)

    results, drifts = run(a.spec_dir, a.snapshot_dir, a.host)

    if a.metrics_file:
        with open(a.metrics_file, "w") as f:
            f.write(render_prometheus(a.host, results, drifts))

    if a.format == "json":
        print(json.dumps({"host": a.host, "results": results, "drifts": drifts}, indent=2))
    else:
        print(render_text(a.host, results, drifts))

    if any(str(v).startswith("error") or v == "no-snapshot" for v in results.values()):
        return 2
    return 1 if drifts else 0


if __name__ == "__main__":
    sys.exit(main())
