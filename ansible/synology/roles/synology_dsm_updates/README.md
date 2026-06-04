# synology_dsm_updates

Manage DSM auto-update policy on e4e-nas from
[`spec/e4e-nas/dsm-updates.yml`](../../../spec/e4e-nas/dsm-updates.yml).

CROSS-REFERENCE: counterpart of nix `system.autoUpgrade` (`nix/profiles/base.nix`)
and the Debian `unattended-upgrades` baseline
(`ansible/roles/base/files/{20auto-upgrades,50unattended-upgrades}`). When you
change the auto-update posture on any layer, mirror it here.

## Coverage

| subcommand | API | model |
|---|---|---|
| `setting` | `SYNO.Core.Upgrade.Setting` v1 (set) | full-object (partial=err 2001) |
| `channel` | `SYNO.Core.Upgrade.Server` v1 (set) | full-object |

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `policy` | `auto_update_type` |
| `auto_install_enabled` | `enable_auto_update` |
| `notify_email_on_install` | `notify_email` |
| `schedule.day` | `upgrade_day` (Sun..Sat) |
| `schedule.hour` | `upgrade_hour` |
| `schedule.minute` | `upgrade_min` |
| `update_channel` | `type` (stable\|beta) on Upgrade.Server |

If a field name differs on the live box (first apply surfaces drift), flip the
`OUT_KEYS` map in [`files/apply_dsm_updates.py`](files/apply_dsm_updates.py) —
single source of truth.

## Warning

A DSM update can revert sshd_config drop-ins written by `synology_ssh` (runbook
§1 historical note). Re-apply `synology_base` after a DSM major upgrade lands.

## Validation

Unit-tested (`files/test_apply_dsm_updates.py`): the OK / WOULD-CHANGE / CHANGED /
FAIL contract, full-object preservation of unmanaged keys, check-mode never-mutates.
End-to-end on the rig pending (rig DOWN at build time).
