# synology_hyper_backup

Declarative DSM Hyper Backup jobs on e4e-nas from
[`spec/e4e-nas/hyper-backup.yml`](../../../spec/e4e-nas/hyper-backup.yml).
This is the OFF-BOX DR layer (runbook §5) — snapshots are local recovery, this
is the "room burned" copy.

Declarative list sync by job `name` (same model as `synology_app_portal`):
create new, update drifted, delete extras. Empty desired list → all live jobs
deleted.

## Coverage

| subcommand | API | model |
|---|---|---|
| `jobs` | `SYNO.SDS.Backup.Client.Task` v1 (list/create/update/delete) | declarative list by name |

## Bootstrap secrets

Destination passwords/keys live OUTSIDE the spec (per-job). Supply at runtime:

    ansible-playbook playbook.yml -e @secrets-hb.yml

Where `secrets-hb.yml` is:

    hyper_backup_secrets:
      critical-shares-offbox: <password-or-key>

**Forward direction:** the long-term source is **OpenBao** at
`secret/e4e-nas/hyper-backup/<job-name>` (KV-v2, same convention as
`secret/krg-prod/grafana-admin` in [`../../../../terraform/grafana/providers.tf`](../../../../terraform/grafana/providers.tf)).
A vault-agent template on `krg-deploy` would render those into
`hyper_backup_secrets` at apply time. Until that wiring lands, the ansible
extra-vars file is the bridge.

The helper SKIPS creating any job marked `encrypt: true` that lacks a secret —
better to skip than create a job without a key.

> **Process-table window.** Backup-destination passwords pass to the DSM
> webapi as positional argv (e.g. `dest_password=<value>`). For the brief
> lifetime of each `synowebapi --exec` invocation, the password is visible
> in `/proc/<pid>/cmdline` to anyone with shell access on the NAS. `no_log`
> hides it from Ansible's logs but can't change DSM's CLI shape. Mitigation:
> the only accounts on the NAS are administrators (synology_users) + AD
> users gated by group filter; `synouser`'s `--enum disabled` confirms
> the built-in `admin`/`guest` are off. Acceptable risk given the
> already-restrictive access posture; flagged here for completeness
> per reviewer 4577021512.

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `name` | `task_name` |
| `destination.type` | `dest_type` |
| `destination.host` | `dest_host` |
| `destination.path` | `dest_path` |
| `sources` | `source_shares` |
| `schedule.daily` | `schedule_time` |
| `schedule.retain_versions` | `retention_count` |
| `encrypt` | `enable_encryption` |
| `enabled` | `enable_task` |

Flip `OUT_KEYS` in
[`files/apply_hyper_backup.py`](files/apply_hyper_backup.py) on drift.

## Open decision: destination

Currently no jobs declared — the spec is a schema-only stub. Open question in
plan.md "Open decisions": rsync target on krg-prod? S3 (Garage)? External NAS?
Pick one, populate `jobs:`, provide `hyper_backup_secrets`, apply.

## Validation

Unit-tested (`files/test_apply_hyper_backup.py`): OK / WOULD-CHANGE / CHANGED /
FAIL contract, create-update-delete classification, check-mode never-mutates,
encrypted-without-secret skip, sources-list order invariance, empty-spec is
no-op. End-to-end on the rig pending.
