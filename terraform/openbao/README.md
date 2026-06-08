# terraform/openbao — OpenBao structure

One target of the [`terraform/`](../README.md) OpenTofu layer. Manages the
**structure** of the OpenBao server on **krg-vault** — secret-engine mounts,
auth methods, roles, and policies — **not** the secret values themselves.

> **Scope: structure, not values.** OpenBao runs on krg-vault; this target only
> declares *where* secrets live and *who* may read them. Secret values are
> written out-of-band (by operators, by `terraform/authentik`'s writeback, or by
> the per-service AppRole flows). Applied from **krg-deploy** after
> `bao operator init` + unseal.

## Why the `hashicorp/vault` provider

OpenBao is a community fork of HashiCorp Vault and deliberately keeps full API
compatibility, so there is no dedicated OpenBao provider — the project's own
guidance is to use `hashicorp/vault` (it can't tell whether it's talking to
Vault or OpenBao). See the header in [`providers.tf`](providers.tf) for the
upstream links.

## What's managed (`main.tf`)

- **KV-v2 mount** at `secret` — the primary store for all KRG secrets.
- **AppRole auth backend** (`approle`) — machine-to-machine auth, no static
  tokens; each system gets a non-secret `role_id` + a secret `secret_id`.
- Two **roles** + matching **policies**:
  - `krg-deploy` — the OpenTofu/Ansible control node. Reads
    `secret/data/krg-deploy/*` and `secret/data/e4e-nas/*` (it runs the
    `synology_*` roles against the prereq-less NAS), and can mint other roles'
    `secret-id`s to bootstrap them on first deploy.
  - `krg-prod` — the lab-wide production stack. Reads `secret/data/krg-prod/*`
    (Authentik, Grafana, Outline, MLflow, …) and renews its own token.

## Outputs (`outputs.tf`)

`krg_deploy_role_id` and `krg_prod_role_id` — the AppRole `role_id`s. These are
**non-secret** and safe to store; the paired `secret_id`s are handled
out-of-band and never land in state.

## Secrets & state

- Credentials: export `TF_VAR_vault_addr` + `VAULT_TOKEN` (a root/admin token)
  before applying. `vault_addr` defaults to `https://krg-vault.ucsd.edu:8200`
  ([`variables.tf`](variables.tf)).
- **State is local for now** — the top-level `terraform/.gitignore` (plus a
  local `.gitignore` in this dir) keeps `*.tfstate*` and `*.tfvars` out of git.
  See [state encryption](../README.md#secrets--state-shared-rules).

```bash
cd terraform/openbao
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<root or admin token>"
tofu init && tofu apply
```
