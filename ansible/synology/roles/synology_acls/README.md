# synology_acls

Manage the DSM **share → principal ACL grant matrix** on the Synology (e4e-nas) from
[`spec/e4e-nas/acls.yml`](../../../spec/e4e-nas/acls.yml); git is the source of truth, UI
changes are drift ([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_acls.py`](files/apply_acls.py) (shipped via the `script` module; DSM py3.8)
wraps `synoshare --setuser <share> {RW|RO|NA} = <list>`:

- **Groups are `@`-prefixed** (`@maya`) — a *bare* group name silently no-ops. Users are bare.
- Reads current tiers with `synoshare --list_acl`, diffs, and only re-sets the tiers that
  drift, with the `=` operator — so the grant list is **authoritative**: a principal omitted
  from the spec is **removed** (e.g. a new share's default `@administrators` RW grant is
  dropped unless you list it). A principal auto-moves to its single tier.

### Spec shape (`acls.yml`)

```yaml
acls:
  - share: maya
    grants:
      - { group: maya, access: rw }     # access: rw | ro | no
      - { group: leads, access: ro }
      - { user: someuser, access: rw }
```

## Scope & the dead-SID caveat

This role applies **share-level** grants (DSM also writes them to the share-root filesystem
ACL). **Preserved data** under a share carries on-disk Windows ACLs referencing the **dead
old-domain SIDs**, which need a recursive "apply to sub-folders and files" pass with
`synoacltool` **after** the `KRG.LOCAL` join — that's a separate post-join runbook step,
not yet applied here.

`acls.yml` ships **empty** (`acls: []`): the authoritative matrix must be **captured from
the live box before the Mode-2 reset** (the config export's ACL blobs reference dead SIDs).

## Run

```bash
ansible-playbook playbook.yml                 # apply share grants
ansible-playbook playbook.yml --check --diff  # report drift
ansible-playbook playbook.yml --tags export   # PRE-RESET CAPTURE → <host>-acls.yml
```

The exporter captures, for **every share in `shares.yml`**, both `synoshare --list_acl`
(share grants) and `synoacltool -get <path>` (filesystem ACLs) — this is the pre-reset ACL
capture the runbook calls for.

## Validation status

Validated on the test rig (DSM 7.3.2-86009): check → apply → idempotent re-run, a
tier-swap, and clear-all, each confirmed via `--list_acl`. A clean full `ansible-playbook`
run awaits the rig getting key auth + NOPASSWD sudo; the real grant matrix awaits the live
box. `apply_acls.py` has pytest unit tests ([`files/test_apply_acls.py`](files/test_apply_acls.py))
covering `desired_tiers`, `parse_list_acl` (against the exact rig `--list_acl` output), and
the only-reset-drifted-tiers apply flow (`pytest files/`, no DSM needed).
