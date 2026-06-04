# synology_snapshot_replication

Per-share Btrfs Snapshot Replication schedule + retention on e4e-nas from
[`spec/e4e-nas/snapshots.yml`](../../../spec/e4e-nas/snapshots.yml).

CROSS-REFERENCE: counterpart of `services.zfs.autoSnapshot` in
[`nix/modules/zfs.nix`](../../../nix/modules/zfs.nix) (waiter — ZFS), and the
[`ansible/roles/nfs_server`](../nfs_server) `zfs-auto-snapshot` timers
(fabricant). Same per-share opt-in retention cadence (hourly/daily/weekly/monthly
keep counts) mirrored across all three layers.

## Coverage

| subcommand | API | model |
|---|---|---|
| `share` | `SYNO.Core.Share.Snapshot` v1 (set, name=<share>) | full-object per share |

## Spec shape

`defaults` covers the common case; `shares:` overrides per share. Shares not
listed get defaults. **Setting `enabled: false` for a share disables snapshots
for it** (opt-out).

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `enabled` | `enable_snapshot` |
| `schedule.hourly` | `keep_hourly` |
| `schedule.daily` | `keep_daily` |
| `schedule.weekly` | `keep_weekly` |
| `schedule.monthly` | `keep_monthly` |

Flip `OUT_KEYS` in [`files/apply_snapshots.py`](files/apply_snapshots.py) on
drift. (DSM Snapshot Replication has separate "take cadence" and "keep" knobs;
the spec exposes the retention/keep counts that align with the ZFS auto-snapshot
model the rest of the fleet uses.)

## Validation

Unit-tested (`files/test_apply_snapshots.py`): OK / WOULD-CHANGE / CHANGED /
FAIL contract, retention-drift detection, disable path, full-object preservation
of unmanaged keys, check-mode never-mutates. End-to-end on the rig pending.
