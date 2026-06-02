# synology_notifications

Manage DSM **notification channels** (mail / SMS / push / CMS) on e4e-nas from
[`spec/e4e-nas/notifications.yml`](../../../spec/e4e-nas/notifications.yml).

## Coverage

| subcommand | API | full-object | spec key |
|---|---|---|---|
| `mail` | `SYNO.Core.Notification.Mail.Conf` v2 | yes | `mail:` |
| `sms`  | `SYNO.Core.Notification.SMS.Conf` v2  | yes | `sms:` |
| `push` | `SYNO.Core.Notification.Push.Conf` v1 | yes | `push:` |
| `cms`  | `SYNO.Core.Notification.CMS.Conf` v2  | yes | `cms:` |

GET → overlay managed keys → SET, only on drift. Nested objects (`smtp_info`, `smtp_auth`
on Mail) are preserved through a sub-GET before merge so unmanaged sub-keys aren't
clobbered.

## Gmail OAuth bootstrap (separate)

`enable_oauth=true` is set here, but the OAuth **token** is acquired by an interactive
DSM UI flow (Control Panel → Notification → Email → Sign in). One-time per rebuild; no
secret in spec.

## Validation

Unit-tested ([`files/test_apply_notifications.py`](files/test_apply_notifications.py)).
End-to-end on the rig pending.
