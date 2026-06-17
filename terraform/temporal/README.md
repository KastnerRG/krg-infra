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
[`terraform/openbao/pki.tf`](../openbao/pki.tf)).

The `platacard/temporal` provider builds its TLS client at **configure time**, so
the cert/key/ca must be known at *plan* time — they can't come from an in-tofu
`vault_pki_secret_backend_cert` resource (the provider would configure before the
resource exists → `tls: failed to find any PEM data`). So `deploy/deploy-tofu.sh`
**mints a short-lived `temporal-client` cert** (one `bao` issuance — matching
cert+key) using krg-deploy's AppRole and passes it in as `TF_VAR_temporal_client_*`.
The cert lives only in env for the run — never in state.

`temporal_host` dials krg-prod directly (resolvable from krg-deploy today);
`temporal_tls_server_name` (`workflows.krg.ucsd.edu`) is what the frontend cert SAN
is verified against, so it works before the public DNS record lands.

## What's managed (`main.tf`)

- `temporal_namespace.this` (for_each `var.namespaces`) — one per namespace.
  `retention` is in **days**. Default set: **`fishsense`**.

## Run

Via `deploy/deploy-tofu.sh` (`TOFU_TARGETS=temporal`), which mints the client cert
(needs `VAULT_TOKEN` = krg-deploy AppRole) and applies. Manually:

```bash
cd terraform/temporal
cj="$(bao write -format=json pki_int/issue/temporal-client common_name=krg-deploy ttl=1h)"
export TF_VAR_temporal_client_cert="$(jq -r .data.certificate <<<"$cj")"
export TF_VAR_temporal_client_key="$(jq -r .data.private_key <<<"$cj")"
export TF_VAR_temporal_ca_cert="$(jq -r .data.issuing_ca <<<"$cj")"
tofu init && tofu apply
```

## Notes

- **Prereqs:** the Temporal stack deployed with mTLS (`docs/temporal-mtls.md`), the
  PKI applied (`terraform/openbao`), and `:7233` reachable from krg-deploy (open at
  the proxmox perimeter — `ansible/.../krg-prod.fw`).
- The client cert/key never lands in state (it flows through provider config, not a
  resource) — but state can still hold namespace metadata, so keep it encrypted per
  the layer's shared rule. The cert itself is short-lived (1h) and re-minted each run.
- **Off-site workers** (e.g. NRP) authenticate the same way: a `temporal-client`
  cert + the CA. Provisioning those for NRP is tracked separately (not in this target).
