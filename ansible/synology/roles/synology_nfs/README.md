# synology_nfs

Manage DSM **NFS service settings and per-share export rules** on the Synology (e4e-nas)
from [`spec/e4e-nas/nfs-exports.yml`](../../../spec/e4e-nas/nfs-exports.yml); git is the
source of truth, UI changes are drift
([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

Two `synowebapi` surfaces, both idempotent (GET/load → diff → SET/save, only on drift),
in [`files/apply_nfs.py`](files/apply_nfs.py) shipped via the `script` module (DSM's
Python 3.8 is below ansible's module floor):

- **`global`** — `SYNO.Core.FileServ.NFS` set: enable NFS / NFSv4 / v4 domain. The `set`
  needs the **full object** (partial = error 2001), like `synology_smb`.
- **`share-rules`** — `SYNO.Core.FileServ.NFS.SharePrivilege` `load`/`save` (param
  `share_name=`). `load` returns `{"rule":[...]}` in the **exact shape** `save` takes back,
  so the spec carries **DSM-native rule objects** and the exporter round-trips them verbatim.

### Rule object (validated on the rig)

```yaml
{ client, privilege: rw|ro, root_squash, async, insecure, crossmnt,
  security_flavor: { sys, kerberos, kerberos_integrity, kerberos_privacy } }
```

`root_squash` is a DSM short enum — `"root"` renders as `no_root_squash` on the wire (root
**not** squashed). Confirm the exact `root_squash`/`security_flavor`/`async` values against
the **live box** (`--tags export` → `load`) before the reset; they're the authoritative
source, not this seed.

> ⚠️ **uid mismatch:** DSM winbind RID-maps AD; the SSSD fleet uses algorithmic mapping, so
> the same AD user gets different uids on the NAS vs Linux clients. SMB is SID-based (fine);
> NFS is uid-based and won't line up — verify uids on fabricant first (runbook §2).

## Run

```bash
ansible-playbook playbook.yml                 # apply (global, then per-share rules)
ansible-playbook playbook.yml --check --diff  # report drift, change nothing
ansible-playbook playbook.yml --tags export   # snapshot → <host>-nfs.yml
```

## Validation status

Validated on the test rig (DSM 7.3.2-86009): `global` and `share-rules` each
drift → `--check` (`WOULD-CHANGE`) → apply (`CHANGED`, `/etc/exports` rendered) → re-run
(`OK no-change`). A clean full `ansible-playbook` run awaits the rig getting key auth +
NOPASSWD sudo. Per-share rule **values** for the real export await the live box.
`apply_nfs.py` has pytest unit tests ([`files/test_apply_nfs.py`](files/test_apply_nfs.py))
covering `_args_from`/`_norm`, the global full-object set, and the share-rules load/diff/save
flow (`pytest files/`, no DSM needed).
