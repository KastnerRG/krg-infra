# terraform/temporal — Temporal namespaces

One target of the [`terraform/`](../README.md) OpenTofu layer. Manages
**namespaces** on the lab-wide Temporal cluster (the `temporalio/auto-setup` stack
on krg-prod, surfaced at `workflows.krg.ucsd.edu`). Temporal's *deployment* lives in
`nix/docker-compose/krg-prod/`; this target owns its namespaces.

## Why a provider (not `tctl`)

Per IaC-strict ([ADR 0001](../../docs/adr/0001-iac-source-of-truth.md)), namespaces
are declared here, not created with a one-off `temporal operator namespace create`
(which would be untracked drift). Adding a namespace = an entry in `var.namespaces`,
commit, apply.

## How it connects (mTLS)

The Temporal gRPC frontend (`:7233`) is published to the internet and **gated by
mutual TLS** — only holders of a client cert from the lab CA's `temporal-client`
role can reach it (see [`docs/temporal-mtls.md`](../../docs/temporal-mtls.md) and
[`terraform/openbao/pki.tf`](../openbao/pki.tf)). This target:

1. Issues itself a **short-lived client cert** via the `vault` provider
   (`vault_pki_secret_backend_cert`, role `temporal-client`) — krg-deploy's AppRole
   holds the issue grant. The key lives only in (encrypted) state.
2. Feeds that cert into the `platacard/temporal` provider's `tls` block and manages
   `temporal_namespace` resources.

`temporal_host` dials krg-prod directly (resolvable from krg-deploy today);
`temporal_tls_server_name` (`workflows.krg.ucsd.edu`) is what the frontend cert SAN
is verified against, so it works before the public DNS record lands.

## What's managed (`main.tf`)

- `vault_pki_secret_backend_cert.deploy_client` — the provider's client cert.
- `temporal_namespace.this` (for_each `var.namespaces`) — one per namespace.
  `retention` is in **days**. Default set: **`fishsense`**.

## Run

Via `deploy/deploy-tofu.sh` (`TOFU_TARGETS=temporal`), which materializes
`VAULT_TOKEN` (krg-deploy AppRole) and applies. Manually:

```bash
cd terraform/temporal
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<krg-deploy AppRole token>"
tofu init && tofu apply
```

> First plan prints a note that the `temporal` provider config depends on
> apply-time values (the client cert) — expected; it resolves during apply.

## Notes

- **Prereqs:** the Temporal stack deployed with mTLS (`docs/temporal-mtls.md`), the
  PKI applied (`terraform/openbao`), and `:7233` reachable from krg-deploy (open at
  the proxmox perimeter — `ansible/.../krg-prod.fw`).
- State holds the client private key → keep it encrypted (the layer's shared rule).
- **Off-site workers** (e.g. NRP) authenticate the same way: a `temporal-client`
  cert + the CA. Provisioning those for NRP is tracked separately (not in this target).
