# ansible/synology — isolated DSM management subtree

All Ansible content for managing the Synology DSM appliance (`e4e-nas`) lives
here, deliberately separate from the main `ansible/` subtree. The boundary
exists so a future NAS decommission (or platform swap) is **one command**:

```bash
rm -rf ansible/synology/
```

…and nothing else in the repo needs editing. No references from the main
subtree, no shared roles, no `roles_path` entries to clean up, no inventory
groups to delete elsewhere.

## What's here

```
ansible/synology/
  ansible.cfg                # local cfg (inventory + roles_path relative)
  inventory.yml              # the `synology` group with e4e-nas
  playbook.yml               # the play composing synology_base + storage roles
  group_vars/
    all.yml                  # shared lookups (keys/passwords/trusted nets) for THIS subtree
    synology.yml             # connection + DSM-specific vars (ansible_user, syno_path, ...)
  roles/                     # all 20 synology_* roles
    synology_base/           # composer
    synology_users/  synology_ssh/  synology_security/  synology_external_access/
    synology_dsm_system/  synology_dsm_web/  synology_dsm_updates/
    synology_security_advisor/  synology_services/  synology_notifications/
    synology_ad/  synology_shares/  synology_acls/  synology_quotas/
    synology_smb/  synology_nfs/  synology_snapshot_replication/
    synology_hyper_backup/  synology_app_portal/
```

## What's NOT here (and why)

- **`spec/e4e-nas/*.yml`** — the declarative specs. Kept at the repo root
  next to the other lab specs because they ARE the source of truth across
  layers (the drift exporter + future fabricant integrations also read them).
  If the NAS goes away, those spec files become orphaned and you can delete
  them at that time — `git grep -l '^# .*synology' spec/e4e-nas/` finds them.
- **`terraform/e4e-nas/`** — Container Manager / scheduler resources for DSM.
  Already its own deletable subtree.
- **`docs/e4e-nas-dsm.md` + `docs/adr/0006-no-oec-on-dsm.md`** — break-glass
  runbook + ADR. Delete with the rest of the NAS surface when decommissioning.

## Running

From this directory:

```bash
cd ansible/synology
ansible-playbook playbook.yml                                       # apply
ansible-playbook playbook.yml --check --diff                        # dry run
ansible-playbook playbook.yml --tags export                         # drift snapshot only
ansible-playbook playbook.yml --tags acls-recursive                 # post-AD-join one-shot
ansible-playbook playbook.yml -e ad_join_password='<pass>'          # AD domain join
ansible-playbook playbook.yml -e @secrets-hb.yml                    # Hyper Backup secrets
```

`ansible.cfg` here overrides the main one when invoked from this directory —
inventory and `roles_path` resolve relative to here, so the main subtree's
content is invisible.

## Decommission procedure

When the NAS is retired or moved off the lab:

```bash
git rm -r ansible/synology/
# Optional cleanup of the spec + terraform + docs (now orphaned):
git rm -r spec/e4e-nas/{shares,acls,smb-globals,nfs-exports,services,security,notifications,dsm-web,dsm-system,app-portal,ssh,users,groups,ad,dsm-updates,security-advisor,external-access,quotas,snapshots,hyper-backup}.yml
git rm -r terraform/e4e-nas/
git rm docs/e4e-nas-dsm.md docs/adr/0006-no-oec-on-dsm.md
```

Nothing in the main `ansible/`, `nix/`, or `drift/` subtrees depends on this
content — verified by no path references and no role imports crossing the
boundary.

## Tests

Unit tests live next to the helpers they cover (one per role's `files/`
directory). Run the whole NAS suite via:

```bash
pytest ansible/synology/roles/ drift/
```

The full `pytest ansible/ drift/` command in the main subtree also picks
these up (pytest recurses).
