# synology_users

Manage **local** DSM users and groups on the Synology (e4e-nas) by wrapping the DSM
CLI (`synouser` / `synogroup`) idempotently — DSM is not Debian, so the native
`ansible.builtin.user`/`group` modules don't apply. Driven by the declarative spec
in [`spec/e4e-nas/`](../../../spec/e4e-nas/); git is the source of truth, UI changes
are drift ([ADR 0001](../../../docs/adr/0001-iac-source-of-truth.md)).

This is the **proof-of-pattern** every `synology_*` role copies: *probe → create-if-missing
(idempotent, `--check`-aware) + a paired read-only exporter that emits the live state*
for drift detection.

## Scope

- **Local users** (`users.yml`) — the service / break-glass accounts. **Human users
  come from the AD domain** (winbind), not this role.
- **Local groups** (`groups.yml`) — only when the spec sets `type: local`. The default
  `type: ad` means group objects live in `KRG.LOCAL` (created with `samba-tool` on the
  DC), so this role skips them.

## Run

```bash
# apply
ansible-playbook playbook.yml
# dry run
ansible-playbook playbook.yml --check --diff
# drift snapshot (read-only) → {{ synology_export_dir }}/<host>-identity.yml
ansible-playbook playbook.yml --tags export
```

Passwords for local users come from a **secret-store-backed** `synology_user_passwords`
map (`-e @secrets.yml` / ansible-vault today) — never from the spec.

**Forward direction (per issue #75):** the eventual source is **OpenBao** at
`secret/e4e-nas/users/<name>` (KV-v2, same convention as
`secret/krg-prod/authentik-managed/grafana-oidc` in [`../../../../terraform/grafana/sso.tf`](../../../../terraform/grafana/sso.tf)).
A vault-agent template on `krg-deploy` would render those values into
`synology_user_passwords` at run time. Until that lands, ansible-vault is the
bridge. **Note:** the SHA-512 hash in `nix/keys/admin-passwords.json#e4e-admin`
is for the Linux *console* fallback only — DSM web UI auth uses its own user
database and needs a plaintext password applied via `synouser --setpw` (issue
#75 tracks the role extension for that).

## Prereqs on the box

SSH enabled; an administrators-group account (NOT built-in `admin`) with key auth +
NOPASSWD sudo; the DSM **Python3** package installed (so ansible modules run). See
`ansible/inventory/group_vars/synology.yml`.

## ⚠️ Pending rig validation

The exact `synouser`/`synogroup` argument + `--enum` output forms are **undocumented
and DSM-version-specific**. They reflect best-known DSM 7.x usage and **must be
validated on the test rig** (`test/`, DS3622xs+/DSM 7.3) before trusting on prod —
that's this milestone's purpose. Group membership/attribute sync is a follow-up
(needs the exporter's current-state diff to stay idempotent).
