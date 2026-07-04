# terraform/incus

The IaC **boundary** of the Incus platform ([ADR 0017](../../docs/adr/0017-incus-nat-self-serve-platform.md) §3).

The `krg.incus` nix module ([nix/modules/incus.nix](../../nix/modules/incus.nix))
stands the Incus **daemon** up on `krg-nat` (the substrate). This root module shapes
**tenancy** on top, reconciled by `tofu plan` like every other target in this layer:

| Resource | What it is |
|---|---|
| `incus_network.nat` | the managed internal NAT (the network the preseed left to tofu) |
| `incus_project.tenant[*]` | one project + resource quota per tenant (the tenancy + quota boundary) |
| `incus_profile.baseline` | platform attachment: NAT nic + root disk on the bootstrap pool |
| `incus_instance.tenant[*]` | the hardened slot (image-gated; the owner deploys the app into it) |

This is the **admin** side of the provision-vs-manage split (ADR 0017 §2,
[ADR 0020](../../docs/adr/0020-tenant-deploy-contract-mktenant.md)): the admin owns the
project / route / quota / isolation here; the owning team manages the interior via
repo-owns-deploy (§8). Adding a tenant is a `var.tenants` entry — a tofu change, not a
host rebuild.

## Auth — fully declarative (no hand-configured remote)

Same mTLS-over-fleet-PKI model as `terraform/temporal` — **nothing is set up by hand**,
nothing lives in a user's `~/.config/incus`:

- `deploy/deploy-tofu.sh` mints a short-lived **client cert** from OpenBao
  (`pki_int/issue/incus-client`) on every apply and writes `client.crt`/`client.key`
  into an ephemeral dir, passed to the provider via `config_dir` (`TF_VAR_incus_config_dir`).
- `krg-nat` **trusts the fleet CA**: the `krg.incus` nix module installs it as Incus's
  `server.ca` and sets `core.trust_ca_certificates=true`, so any fleet-signed client cert
  is accepted — **no per-cert `incus config trust add`**.
- `accept_remote_certificate` trusts krg-nat's server cert on the trusted internal segment.

The API is **ucsd+ops-restricted** at the firewall (the nix module's `sourcedPorts`) and
OIDC-gated for humans; this cert is the machine identity. No secret in tfvars, no drift.

## Apply

Via the control node (needs `openbao` applied first for the `incus-client` PKI role +
the krg-deploy grant, and the `krg-nat` host deployed with the CA-trust module):

```sh
TOFU_TARGETS="openbao incus" ./deploy/deploy-tofu.sh
```

State is local + encrypted on krg-deploy (ADR 0005), same as the other targets. The
`tenants` map is empty by default, so this is **inert until tenants are declared**.

## Status / bring-up gates

- **Provider-attribute verification** — DONE. Applied live against `krg-nat`; the
  boundary (`incusbr0` NAT + the `krg-baseline` profile) is created and steady-state
  converged (`0 added, 0 changed`). Tenant projects/instances stay inert until declared.
- **Golden-template image** — DONE. The hardened template (AD-join, key-only SSH,
  auto-upgrade, monitoring, in-guest firewall — ADR 0017 §7, MINUS OEC which follows
  persistence) is built from `nixosConfigurations.krg-golden` (`nix/golden/`) and
  published to krg-nat's image store as `krg-golden` by `deploy/incus-publish-golden.sh`
  (CD phase 2.7). Point a tenant at it with `tenants.<name>.image = "krg-golden"`; the
  instance then converges to its full config via the tenant's own flake (repo-owns-deploy).
  Remaining §7 item: central-logging shipper, deferred until the Loki push endpoint lands.
- **Edge ingress route** — SETTLED (`forwards.tf`). Egress NAT is automatic; INGRESS is
  an `incus_network_forward`: the zone edge dials `incus_host_ip:<edge_port>` (krg-nat's
  own IP) and Incus DNATs to the tenant's pinned `nat_ip:443`. Chosen over an L3 route
  (Incus masquerades the return path — validated on-box) and over a shared bridge
  (Proxmox-dependent; the platform is moving off Proxmox). Expose a tenant with
  `nat_ip` + `edge_port`; the `tenant_edge_backends` output gives the edge `backend`.
  Verify the forward end-to-end on first apply (curl the edge → instance path).
