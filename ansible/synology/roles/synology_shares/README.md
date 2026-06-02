# synology_shares

Manage DSM **shared folders** on the Synology (e4e-nas) by wrapping the DSM CLI
(`synoshare`) idempotently — DSM is not Debian, so there is no native ansible
shared-folder module. Driven by the declarative spec in
[`spec/e4e-nas/shares.yml`](../../../spec/e4e-nas/shares.yml); git is the source of
truth, UI changes are drift ([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

Copies the [`synology_users`](../synology_users/) proof-of-pattern: *probe →
create-if-missing (idempotent, `--check`-aware) + a paired read-only exporter that emits
the live state* for drift detection.

## Scope

- **Create shared folders** declared in `shares.yml` (name, path, description,
  browseable). Per-share **user ACLs** (`synoshare --setuser`) belong to the future
  `synology_acls` role, not here.
- **Not yet** (follow-ups; all need the exporter's current-state diff to stay
  idempotent): description/browse drift correction (`--setdesc` / `--setbrowse`),
  recycle-bin (no `synoshare` arg — a separate file-service setting), rename / volume
  move (`--rename` / `--setvol`).

## `synoshare --add` & the burn-down/rebuild goal

Validated on the test rig (DSM 7.3.2-86009, btrfs volume):

| target leaf path           | result                                            |
|----------------------------|---------------------------------------------------|
| does not exist             | creates the btrfs subvolume + share (rc 0)        |
| existing **btrfs subvolume** | re-links the share to it, **data preserved** (rc 0) |
| existing **plain dir**     | fails `share create failed [0xE700]` (rc 255)     |
| share name already exists  | fails `Share is already exists.` (rc 255)         |

DSM creates every shared folder as a btrfs **subvolume**, so after a clean DSM
reinstall with preserved volumes, re-running this role re-attaches each share to its
existing data — that's the "burn it down and stand it back up" path. (The plain-dir
failure is a rig artifact of hand-`mkdir`-ing a non-subvolume; it won't occur on a real
preserved volume.) We probe with `--get` first, so the "already exists" error never
fires on a converged box.

## Run

```bash
# apply (all synology roles)
ansible-playbook playbook.yml
# dry run
ansible-playbook playbook.yml --check --diff
# drift snapshot (read-only) → {{ synology_export_dir }}/<host>-shares.yml
ansible-playbook playbook.yml --tags export
```

## Prereqs on the box

SSH enabled; an administrators-group account (NOT built-in `admin`) with key auth +
NOPASSWD sudo; the **User Home** service enabled. Roles use `raw` (DSM's Python 3.8 is
below ansible's module floor) and prepend `{{ syno_path }}` (`/usr/syno/sbin:/usr/syno/bin`).
See [`group_vars/synology.yml`](../../inventory/group_vars/synology.yml).

## ⚠️ Validation status

`synoshare --add`/`--get`/`--enum` argument + return-code behaviour validated on the
test rig (`test/`, DS3622xs+/DSM 7.3.2-86009) — see the table above. The `--enum` output
*parse* into the spec shape (the exporter) is still pending rig validation.
