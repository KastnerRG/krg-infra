# synology_ad

DSM Active Directory domain join (KRG.LOCAL) + winbind idmap reconciliation
from [`spec/e4e-nas/ad.yml`](../../../spec/e4e-nas/ad.yml).

CROSS-REFERENCE: counterpart of nix `krg.adClient`
([`nix/modules/sssd-ad-client.nix`](../../../nix/modules/sssd-ad-client.nix))
and ansible [`roles/ad_client`](../ad_client). Same realm/DC. DSM uses winbind
(not SSSD), and that's where the idmap-reconciliation work below comes from.

## The NFS-interop blocker (runbook §2)

DSM/winbind defaults to **RID** mapping; SSSD on the rest of the fleet uses
**algorithmic**. Same AD user → different uid/gid on the NAS vs Linux clients.
- SMB enforces by SID (fine).
- NFS enforces by uid — `fabricant-prod-share` export to fabricant-prod
  **breaks** unless you align the idmap ranges.

The spec exposes `idmap_mode` (rid|autorid) plus explicit `idmap_uid_range` /
`idmap_gid_range` matching the SSSD side. If you change SSSD's range,
mirror it here.

## Order constraint

`synology_base` runs this LAST — local `e4e-admin` (`synology_users`; E4E
hardware) and key-only SSH (`synology_ssh`) are already in place, so a
misconfigured idmap or allowed-groups filter can't lock you out (local
accounts bypass winbind).

## Coverage

| subcommand | API | model |
|---|---|---|
| `domain-config` | `SYNO.Core.Directory.Domain` v1 (set) | full-object (partial=err 2001) |
| `test-join` | `SYNO.Core.Directory.Domain.Join` v1 (test) | read-only |
| `join` | `SYNO.Core.Directory.Domain.Join` v1 (start) | one-shot, needs creds |

## One-time join (bootstrap secret)

The join needs Domain Admin credentials, passed at runtime (NEVER stored):

    ansible-playbook playbook.yml \
      -e ad_join_user=Administrator -e ad_join_password='<PASSWORD>'

**Forward direction:** the long-term source is **OpenBao** at
`secret/e4e-nas/ad/join-credential` (KV-v2, same convention as
`secret/krg-prod/*` in the krg-prod-side workspaces). A vault-agent template
on `krg-deploy` reads it at apply time and supplies `ad_join_password` as an
extra-var; the secret rotates in OpenBao without re-typing anything. After the
NAS is joined, no creds are needed on routine runs.

A run **without** the password on an un-joined NAS stages config and warns
rather than failing the play (mirrors `ad_client`'s ergonomics) — re-run with
the password later.

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `realm` | `realm` |
| `domain` | `nbns_name` |
| `dc_host` | `server_address` |
| `dc_ip` | `server_ip` |
| `ou` | `ou` |
| `idmap_mode` | `idmap_type` |
| `idmap_uid_range` | `idmap_uid` |
| `idmap_gid_range` | `idmap_gid` |
| `allowed_groups` | `allowed_groups` |
| `admin_groups` | `domain_admin_groups` |

Flip `OUT_KEYS` in [`files/apply_ad.py`](files/apply_ad.py) on first-apply drift.

## Validation

Unit-tested (`files/test_apply_ad.py`): OK / WOULD-CHANGE / CHANGED / FAIL
contract, full-object preservation, idmap drift detection, allowed-groups order
invariance, JOINED/NOT-JOINED gating, join-failure path. End-to-end on the rig
pending (rig DOWN at build time).
