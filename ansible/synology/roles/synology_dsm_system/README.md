# synology_dsm_system

Manage DSM **hostname / gateway / DNS** on e4e-nas from
[`spec/e4e-nas/dsm-system.yml`](../../../spec/e4e-nas/dsm-system.yml).

## Coverage (this iteration)

| subcommand | API | spec |
|---|---|---|
| `network` | `SYNO.Core.Network` v2 set | `system.hostname`, `network.gateway`, `network.dns.*` |

Full-object set, GET → overlay → SET only on drift.

## Out of scope (TODO)

- **NTP server** — the SET API isn't confirmed on this DSM (`Region.NTP` /
  `System.Conf` candidates; capture didn't include them). Probe + add `ntp` subcommand.
- **Per-interface static IP / netmask** — `SYNO.Core.Network.Ethernet` v2 set takes a
  larger object than this iteration handles. The live IP already matches the spec, so
  this is currently a no-op-by-default; add `ethernet` subcommand when re-IP'ing.
- **Timezone** — `SYNO.Core.Region.*` namespace; not yet driven.

## Validation

Unit-tested ([`files/test_apply_dsm_system.py`](files/test_apply_dsm_system.py)). End-to-
end on the rig pending. **`network` set is a dangerous category — wrong values can lock
you out** — always run `--check --diff` first against the live box.
