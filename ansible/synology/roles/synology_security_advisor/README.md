# synology_security_advisor

Manage DSM Security Advisor (scheduled vuln/config scan + email notify) on
e4e-nas from
[`spec/e4e-nas/security-advisor.yml`](../../../spec/e4e-nas/security-advisor.yml).

CROSS-REFERENCE: this is the DSM-native replacement for `oec_qualys_trellix` on
Linux hosts. Same intent — periodic vuln/config scan with email notify on
findings; different mechanism (Synology-curated, matches the appliance threat
model). See `docs/adr/0006-no-oec-on-dsm.md`.

## Coverage

| subcommand | API | model |
|---|---|---|
| `main` | `SYNO.Core.SecurityScan.Conf` v1 (set) | full-object (partial=err 2001), wrapped in DSM 7.3's `Input` envelope |

The captured scheduled task on the 2026-05-28 NAS triggered
`SYNO.Core.SecurityScan.Operation start`. The schedule is owned by
`SecurityScan.Conf` (validated empirically — the initial `.Main` guess was
wrong on DSM 7.3, corrected in
[`files/apply_security_advisor.py`](files/apply_security_advisor.py)).

## Field mapping (validated on DSM 7.3 e4e-nas 2026-06-01)

| Spec field | DSM field (Conf) |
|---|---|
| `enabled` | `enableSchedule` |
| `schedule.day` | `weekday` (0=Sun..6=Sat) |
| `schedule.hour` | `hour` |
| `schedule.minute` | `minute` |
| `scan_categories` | per-category `group_set` (`SYNO.Core.SecurityScan.Conf.group_set`) |
| `notify_email_on_finding` | covered by the notifications role, not Conf |

If a field name differs on a different DSM build, flip `OUT_KEYS` in the helper.

## Validation

Unit-tested (`files/test_apply_security_advisor.py`): the OK / WOULD-CHANGE /
CHANGED / FAIL contract, full-object preservation of unmanaged keys, check-mode
never-mutates, category-list order invariance. End-to-end on the rig pending
(rig DOWN at build time).
