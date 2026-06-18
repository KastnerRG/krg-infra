# `ansible/krg-ad/` — KRG.LOCAL Active Directory as IaC

Self-contained Ansible subtree that converges the **KRG.LOCAL** Samba AD forest
(on `krg-ldap`) to the declarative spec in [`spec/krg-ad/`](../../spec/krg-ad/).
It wraps `samba-tool` on the DC. Rationale + ownership boundary:
[ADR 0010](../../docs/adr/0010-active-directory-structure-as-iac.md).

Like `ansible/synology/`, everything (inventory, group_vars, playbook, role)
lives under this dir, so a decommission is one command: `rm -rf ansible/krg-ad/`.
It is intentionally NOT in the main `ansible/inventory/hosts.yml` (those are the
Proxmox/Debian hypervisors; this is a NixOS DC reached over SSH).

## Scope (and the roster boundary)

This subtree owns the **structural** content of the directory:

- **Group objects** — `spec/krg-ad/groups.yml`
- **Service / automation accounts + their group membership** — `service-accounts.yml`
- **Delegated ACL grants** — `acls.yml`
- **Domain password policy** — `password-policy.yml`

It does **not** own **human accounts or their group membership** — those are
**roster** (`svc_roster`). The apply is therefore **non-authoritative**: it only
ever adds groups / memberships / ACEs and converges the policy; it never deletes.
This is what lets roster and IaC both write the directory without fighting.

## Run

```bash
cd ansible/krg-ad
ansible-playbook playbook.yml --check --diff   # dry run — reports drift, mutates nothing
ansible-playbook playbook.yml                  # converge
```

From the control node (krg-deploy): `DEPLOY_KRG_AD=true deploy/deploy-ansible.sh`.

## Prereqs

- SSH reachability to `krg-ldap` (137.110.161.109) as `krg-admin` (key-only),
  with `become` (sudo) — the break-glass admin. SSH to the DC is source-restricted
  to ucsd+ops, so run from in-fleet.
- `python3` on `krg-ldap` (added by `nix/modules/samba-ad.nix`) for ansible's
  modules + `apply_krg_ad.py`. `samba-tool` is already present (the DC package).

## Tests

`pytest ansible/krg-ad/` (or the repo-wide `pytest ansible/ drift/`). The tests
mock `samba-tool`, so no DC is needed.
