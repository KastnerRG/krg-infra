# drift/ — configuration drift detector

`git` is the single source of truth; **any UI change to a managed target is drift**
([ADR 0001](../docs/adr/0001-iac-source-of-truth.md)). This tool detects and surfaces it
for the Synology NAS (`e4e-nas`).

## How it fits together

```
synology_* roles (apply)          spec/e4e-nas/*.yml  ── desired state
        │                                  │
        │  --tags export                   │
        ▼                                  ▼
  live-state snapshots  ──────▶  drift_detector.py  ──▶  report + Prometheus metrics
  (<host>-{shares,smb,nfs,acls}.yml)                      (textfile collector → alerts)
```

The `synology_*` role **exporters** (`ansible-playbook ansible/synology/playbook.yml --tags
export`) write per-host live-state snapshots to a directory. `drift_detector.py` reads
those snapshots + the spec and diffs them — **it touches no NAS itself**, so it runs
anywhere (the intended home is **krg-deploy**, on a systemd timer that runs the export then
the detector, writing metrics into node_exporter's textfile-collector dir → the krg-prod
Prometheus → Grafana/alerts).

Keeping detection in a separate tool that consumes snapshots (rather than a live query)
means the diff logic is **unit-testable offline** and a captured snapshot is an audit record.

## Usage

```bash
drift_detector.py --spec-dir spec/e4e-nas \
    --snapshot-dir /var/lib/krg-deploy/synology-export --host e4e-nas \
    [--metrics-file e4e-nas-drift.prom] [--format text|json]
```

Exit code: **0** no drift · **1** drift detected · **2** error (missing/unparseable
snapshot or spec — e.g. a stale capture). Resources covered: **shares** (presence),
**SMB** globals, **NFS** (global + per-share rules), **share ACLs**. Each diff mirrors the
field mapping of the matching `synology_*` apply helper.

## Metrics

```
krg_synology_drift{host,resource}                 1 = drift, 0 = in sync
krg_synology_drift_items{host,resource}           number of drifted keys
krg_synology_drift_check_success{host}            1 = all snapshots present + parsed
krg_synology_drift_check_timestamp_seconds{host}  unix time of the check
```

Alert on `krg_synology_drift > 0` (someone changed the NAS in the UI) and on
`krg_synology_drift_check_success == 0` (the capture is broken/stale — drift status unknown).

## Tests

```bash
pip install pytest pyyaml && pytest drift/ -q   # or via the CI (.github/workflows/tests.yml)
```

Fixtures use the real DSM output shapes captured on the rig (version-3 SMB GET, NFS load,
`--list_acl`, `--enum`). Validated end-to-end against live rig output through the full
snapshot path. Roadmap: dump users/groups drift; extend to the OpenTofu targets.
