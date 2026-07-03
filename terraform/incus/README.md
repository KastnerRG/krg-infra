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

- **Provider-attribute verification** — written against the `lxc/incus` provider
  schema and `tofu validate`-clean, but not yet applied against a live server (the
  `krg-nat` host is being provisioned). Verify on first `plan` like the e4e-nas target.
- **Golden-template image** — instances are `image`-gated and stay empty until the
  hardened template (AD-join, key-only SSH, auto-upgrade, monitoring, central logging —
  ADR 0017 §7) is published. Boundary (project + quota + profile + network) applies now.
- **Edge ingress route** — egress NAT is automatic; an edge reaching an instance needs
  the ingress path settled at bring-up (see the `krg-nat` host config).
