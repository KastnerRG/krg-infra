# terraform/ — the OpenTofu layer

The third config layer of `krg-infra`, alongside `nix/` (NixOS machines) and
`ansible/` (Proxmox hypervisors). This layer manages things driven through a
**Terraform/Web-API provider** rather than NixOS or Ansible — appliances and
running services that expose their config over an API.

Use **OpenTofu** (`tofu`), not HashiCorp Terraform: FOSS, in nixpkgs
(`nix run nixpkgs#opentofu`), and native state encryption (see below).

## Layout: one root module per target

Each target is its **own root module** in its own subdirectory — its own
`tofu init`, its own **state**, its own credentials, its own `apply`. They are
**not** combined into one config: different providers, lifecycles, blast radii,
and secrets. A NAS `apply` must not be able to touch Vault's state.

| Target | Provider | Manages | Status |
|---|---|---|---|
| [`e4e-nas/`](e4e-nas/) | `synology-community/synology` | Synology DSM: Container Manager package + FileStation folders (active); scheduler/VMs scaffolded (+ runbook for the rest) | **built (hybrid)** — most of DSM has no API; see ADR 0007 |
| [`authentik/`](authentik/) | `goauthentik/authentik` + `hashicorp/vault` + `hashicorp/random` | Authentik **SSO config**: applications, OAuth2/OIDC + proxy providers, LDAP source/outpost, groups; writes OIDC client secrets into OpenBao | **built** |
| [`openbao/`](openbao/) | `hashicorp/vault` (OpenBao is API-compatible) | OpenBao **structure**: KV-v2 mount, AppRole auth, per-consumer policies (krg-deploy, krg-prod) | **built** |
| [`grafana/`](grafana/) | `grafana/grafana` + `hashicorp/vault` | Grafana objects: data sources, folders, dashboards, SSO via Authentik (creds from OpenBao) | **built** |

> `authentik/`, `openbao/`, and `grafana/` manage the *configuration of* services
> that are **deployed elsewhere** (Authentik + Grafana are compose stacks on
> krg-prod; OpenBao runs on krg-vault). Terraform owns their objects, not their
> deployment. Each needs the service running + an API token before it can plan
> — see each subdir's README.
>
> **Replaced HashiCorp Vault with OpenBao.** The original plan was a `vault/`
> target using `hashicorp/vault`; we switched to OpenBao (the fully-FOSS Vault
> fork) — see `openbao/`. The `vault/` README stub has been removed. The
> `grafana/` + `authentik/` workspaces use the `hashicorp/vault` *provider*
> (it speaks the same API OpenBao implements) to read/write secrets against
> the OpenBao server.

## Secrets & state (shared rules)

- Credentials per target: `terraform.tfvars` (gitignored) or `TF_VAR_*` env vars.
- **State holds secrets** and is **local for now** — the top-level
  `.gitignore` keeps `*.tfstate*` and `*.tfvars` out of git for every target.
  We will migrate to a remote backend ("start local and we'll migrate it").
- Vault/Authentik state is especially sensitive (tokens, possibly secret
  values), so sort out a backend + state encryption **before** those go live.
- **State encryption** (OpenTofu): the `encryption` block can't read variables,
  so supply it via the `TF_ENCRYPTION` env var to keep the passphrase out of the
  repo:

  ```bash
  export TF_ENCRYPTION='
  key_provider "pbkdf2" "k" { passphrase = "'"$TOFU_STATE_PASSPHRASE"'" }
  method "aes_gcm" "m"      { keys = key_provider.pbkdf2.k }
  state { method = method.aes_gcm.m }
  plan  { method = method.aes_gcm.m }
  '
  ```

  `deploy/deploy-tofu.sh` assembles this block for you from
  `TOFU_STATE_PASSPHRASE` and **hard-fails** rather than writing plaintext state
  if a credentialed target runs without it (ADR 0005).

### Generating, storing, and rotating `TOFU_STATE_PASSPHRASE`

The passphrase is **generated once, not retrieved** — any high-entropy string
works (PBKDF2 derives the AES key from it); the only constraint is **no newline**.

1. **Generate + store durably FIRST.** If it is ever lost the encrypted state is
   **unrecoverable** (no reset — you would `tofu import` every resource back).
   Stash it in the lab password manager (`vaultwarden.krg.ucsd.edu`), not in
   OpenBao — OpenBao is itself a tofu target, so keeping the state key outside it
   avoids a recovery circular-dependency.

   ```bash
   openssl rand -base64 48     # store the output as krg-infra / TOFU_STATE_PASSPHRASE
   ```

2. **Set the repo Actions secret** (what `deploy.yml` injects):

   ```bash
   gh secret set TOFU_STATE_PASSPHRASE --repo KastnerRG/krg-infra
   ```

3. **Mirror it on krg-deploy** for hand-runs of `deploy/deploy-tofu.sh` — it must
   be the **same value** the Actions secret holds, or CI and local applies produce
   two incompatibly-encrypted states. Export it in krg-admin's environment there.

**Rotating** is a re-encrypt cycle, not a swap: set the new passphrase as a
`key_provider` alongside the old one with `state { method = ... fallback { ... } }`
so OpenTofu can decrypt with the old key and re-write with the new on the next
`apply`, then drop the fallback once every target's state has been rewritten.
Generate once and leave it — rotation is deliberately more involved than `gh
secret set`.

## Shared source of truth

Targets read the same shared JSON the other layers do (don't duplicate values):

```hcl
locals {
  trusted = jsondecode(file("${path.module}/../../nix/networks/trusted.json"))
  admins  = jsondecode(file("${path.module}/../../nix/keys/admins.json"))
}
```
