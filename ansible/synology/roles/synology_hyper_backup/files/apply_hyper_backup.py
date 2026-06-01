#!/usr/bin/env python3
"""Apply DSM Hyper Backup job set declaratively via synowebapi.

One subcommand:
  jobs   SYNO.SDS.Backup.Client.Task list/create/update/delete (v1) — declarative
         list sync by job `name`. Desired list = spec; create new, update drifted,
         delete extras. Empty desired = delete all.

Run by synology_hyper_backup role via `script:` (DSM py3.8).
OK / WOULD-CHANGE <json> / CHANGED <json> / FAIL <json>.

Field mapping (DSM 7.3 best-known — empirical confirmation pending; flip
OUT_KEYS/normalize() in this file on first-apply drift):
  name                 -> task_name
  destination.type     -> dest_type        ("rsync"|"s3"|"webdav"|"hyperbackup-vault")
  destination.host     -> dest_host
  destination.path     -> dest_path
  sources              -> source_shares    (list of share names)
  schedule.daily       -> schedule_time    ("HH:MM")
  schedule.retain_versions -> retention_count
  encrypt              -> enable_encryption
  enabled              -> enable_task

Secrets (per-job password/key) come via --secrets <JSON map> and are passed to
create/update calls as DSM expects (best-known: `dest_password=` for rsync,
`access_key_secret=` for s3 — flip when probing).
"""
import argparse
import json
import subprocess
import sys

WEBAPI = "/usr/syno/bin/synowebapi"
TASK_API = "SYNO.SDS.Backup.Client.Task"

OUT_KEYS = {
    "name":              "task_name",
    "dest_type":         "dest_type",
    "dest_host":         "dest_host",
    "dest_path":         "dest_path",
    "sources":           "source_shares",
    "schedule_daily":    "schedule_time",
    "retain":            "retention_count",
    "encrypt":           "enable_encryption",
    "enabled":           "enable_task",
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


def _flatten(job, defaults):
    """Spec entry (nested) -> flat DSM-field dict for comparison and SET."""
    out = {
        OUT_KEYS["name"]:         job["name"],
        OUT_KEYS["dest_type"]:    job.get("destination", {}).get("type"),
        OUT_KEYS["dest_host"]:    job.get("destination", {}).get("host"),
        OUT_KEYS["dest_path"]:    job.get("destination", {}).get("path"),
        OUT_KEYS["sources"]:      sorted(job.get("sources", [])),
        OUT_KEYS["schedule_daily"]: job.get("schedule", {}).get("daily"),
        OUT_KEYS["retain"]:       job.get("schedule", {}).get("retain_versions"),
        OUT_KEYS["encrypt"]:      job.get("encrypt", defaults.get("encrypt", True)),
        OUT_KEYS["enabled"]:      job.get("enabled", defaults.get("enabled", True)),
    }
    return out


def _normalize(live_entry):
    """Live task -> flat dict comparable to _flatten output (sort lists)."""
    out = dict(live_entry)
    if isinstance(out.get(OUT_KEYS["sources"]), list):
        out[OUT_KEYS["sources"]] = sorted(out[OUT_KEYS["sources"]])
    return out


def _diff_one(desired, live):
    return {k: {"current": live.get(k), "desired": v}
            for k, v in desired.items() if live.get(k) != v}


def do_jobs(a):
    desired_list = json.loads(a.desired) if a.desired else []
    defaults = json.loads(a.defaults) if a.defaults else {}
    secrets = json.loads(a.secrets) if a.secrets else {}

    live = _exec(TASK_API, "version=1", "method=list").get("data", {}).get("tasks", []) or []
    live_by_name = {t.get(OUT_KEYS["name"]) or t.get("name"): t for t in live}
    desired_by_name = {j["name"]: _flatten(j, defaults) for j in desired_list}

    creates, updates, deletes = [], [], []
    for name, want in desired_by_name.items():
        # Skip encrypted-but-no-secret jobs (the role's assert already warned).
        if want.get(OUT_KEYS["encrypt"]) and name not in secrets:
            continue
        if name not in live_by_name:
            creates.append(name)
        else:
            d = _diff_one(want, _normalize(live_by_name[name]))
            if d:
                updates.append({"name": name, "drift": d})
    for name in live_by_name:
        if name not in desired_by_name:
            deletes.append(name)

    if not creates and not updates and not deletes:
        print("OK no-change")
        return 0

    summary = {"creates": creates, "updates": [u["name"] for u in updates], "deletes": deletes}
    if a.check:
        print("WOULD-CHANGE " + json.dumps(summary, sort_keys=True))
        return 0

    for name in creates:
        params = dict(desired_by_name[name])
        if name in secrets:
            params["dest_password"] = secrets[name]
        r = _exec(TASK_API, "version=1", "method=create", *_args_from(params))
        if not r.get("success"):
            print("FAIL " + json.dumps({"create": name, "res": r}))
            return 1
    for u in updates:
        name = u["name"]
        params = dict(desired_by_name[name])
        # Include id from live so DSM knows which task to mutate
        params["id"] = live_by_name[name].get("id")
        if name in secrets:
            params["dest_password"] = secrets[name]
        r = _exec(TASK_API, "version=1", "method=update", *_args_from(params))
        if not r.get("success"):
            print("FAIL " + json.dumps({"update": name, "res": r}))
            return 1
    for name in deletes:
        params = {"id": live_by_name[name].get("id")}
        r = _exec(TASK_API, "version=1", "method=delete", *_args_from(params))
        if not r.get("success"):
            print("FAIL " + json.dumps({"delete": name, "res": r}))
            return 1

    print("CHANGED " + json.dumps(summary, sort_keys=True))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Apply DSM Hyper Backup job set declaratively.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("jobs")
    j.add_argument("--desired", required=True, help="JSON list of jobs")
    j.add_argument("--defaults", required=True, help="JSON object of spec defaults")
    j.add_argument("--secrets", required=True, help="JSON map: job name -> password/key")
    j.add_argument("--check", action="store_true")
    j.set_defaults(func=do_jobs)
    a = ap.parse_args(argv)
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
