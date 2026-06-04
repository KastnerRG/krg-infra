# synology_external_access

Disable DSM's relay / NAT-pierce surfaces on e4e-nas from
[`spec/e4e-nas/external-access.yml`](../../../spec/e4e-nas/external-access.yml).

QuickConnect and UPnP both bypass the in-DSM firewall perimeter that
`synology_security` sets up — the runbook §3 line "they bypass this perimeter
via Synology's relay" describes exactly the behavior this role kills.

## Coverage

| subcommand | API | model |
|---|---|---|
| `quickconnect` | `SYNO.Core.QuickConnect` v1 (set) | full-object (partial=err 2001) |
| `upnp` | `SYNO.Core.Network.Router.UPnP` v1 (set) | full-object |
| `ddns` | `SYNO.Core.ExternalAccess.DDNS` v1 (set) | full-object |

## Order constraint

The `synology_base` composer runs this AFTER `synology_security` so the
perimeter is asserted first, then we make sure nothing punches around it.

## Field mapping (best-known; verify on first rig apply)

All three surfaces flip a single `enabled` boolean — flip values in `OUT_KEYS`
inside [`files/apply_external_access.py`](files/apply_external_access.py) if a
field name differs on the live box (some DSM versions use `enable_*` instead of
plain `enabled`).

## Validation

Unit-tested (`files/test_apply_external_access.py`): OK / WOULD-CHANGE /
CHANGED / FAIL contract, full-object preservation of unmanaged keys (DDNS test),
check-mode never-mutates, each subcommand targets the correct API. End-to-end on
the rig pending.
