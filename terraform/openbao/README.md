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

## PKI: lab-internal CA (`pki.tf`)

A **private two-tier CA** (root → intermediate) for mutual-TLS *between lab
services* — deliberately separate from the public Let's Encrypt certs Traefik
issues for browser HTTPS (mTLS certs can't be public-CA issued, and these are
machine endpoints). The root signs **only** the intermediate; every leaf comes
from the intermediate, so leaf-issuing trust rotates without touching the root.

- **`pki`** (root, 10y) → **`pki_int`** (intermediate, 5y), EC P-256 throughout.
  Root/intermediate keys are `type = "internal"` — generated in OpenBao, never
  exported.
- Issuing **roles** on `pki_int`:
  - `temporal-frontend` — the Temporal gRPC frontend's **server** cert (krg-prod
    `vault-agent` issues it, renders cert+key to `/run` tmpfs, auto-renews). SANs
    from `var.temporal_frontend_domains`.
  - `temporal-client` — **client** certs for callers of the frontend (the
    `terraform/temporal` provider, workers, the UI). `server_flag` off.
  - `host` — general-purpose **server** cert for any lab host/service (waiter's
    XRDP, future internal services). FQDN under `var.host_allowed_domains`
    (`krg.local` / `krg.ucsd.edu`), subdomains allowed. Issued+renewed by the
    host's `vault-agent`.
  - `user` — **client** cert bound to an AD identity: the user's UPN is stamped
    into an `otherName` SAN (OID `1.3.6.1.4.1.311.20.2.3`, the AD/PKINIT UPN
    extension), so the cert *is* the AD principal. Short-lived; minted by the user
    via the AD-gated grants below. PKINIT-ready by design.
- Grants: `krg-deploy` may issue `temporal-client`; `krg-prod` may issue
  `temporal-frontend` (+ the UI client cert). Folded into the AppRole policies in
  `main.tf` via `local.pki_*_rules`. **Reading** the CA/CRL needs no grant —
  `pki_int/ca`, `/ca/pem`, `/crl` are unauthenticated by design.

## AD-backed issuance (`ldap.tf`)

The PKI is **hooked into Active Directory**: who may mint which cert is decided by
AD group membership, the same authority model as host logins and Grafana SSO.

- **`ldap` auth backend** bound to `KRG.LOCAL` over LDAPS. *Machines* keep using
  AppRole (a host isn't an AD user); *humans* authenticate here to mint their own
  `user` client certs.
- **`var.pki_ad_group_roles`** maps each AD group → the `pki_int/issue/<role>`s its
  members get. `ldap.tf` renders one least-privilege policy + group binding per
  entry. Default: `Domain Admins → {host, user, temporal-client}`; widen as needed
  (e.g. `ARM-PDK → {user}`).
- **Bootstrap caveat**: LDAPS verification uses `var.ldap_ca_cert` — Samba's
  self-signed cert at first, swappable to the lab root once the DC cert is
  re-issued from `pki_int`. `binddn`/`bindpass`/`ldap_ca_cert` have no defaults;
  supply `bindpass` via `TF_VAR_ldap_bindpass`. **Prerequisites (AD-side, manual):
  see [`docs/pki-ad-integration.md`](../../docs/pki-ad-integration.md).**

> First consumer is Temporal (frontend mTLS, `TEMPORAL_TLS_REQUIRE_CLIENT_AUTH`)
> — see `terraform/temporal/` and `nix/docker-compose/krg-prod/compose.temporal.yml`.
> The CA is generic, though: any future lab service needing mTLS adds a role here,
> and the fleet trusts the CA root via `nix profiles/base.nix` (`security.pki`).

## Outputs (`outputs.tf`)

`krg_deploy_role_id` and `krg_prod_role_id` — the AppRole `role_id`s. These are
**non-secret** and safe to store; the paired `secret_id`s are handled
out-of-band and never land in state. `pki_int_ca_cert` — the intermediate CA
certificate (PEM, non-secret trust anchor; also at `…/v1/pki_int/ca/pem`).

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
