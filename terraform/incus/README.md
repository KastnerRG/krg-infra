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

## Auth

`krg-deploy` authenticates with a **client certificate trusted by `krg-nat`**, set up
once at bring-up:

```sh
# on krg-nat (the server):
incus config trust add --name krg-deploy        # prints a one-time trust TOKEN

# on krg-deploy (the client):
incus remote add krg-nat <token>                 # mints the client cert, stores the remote
```

The provider then reads that cert from the incus config dir on every run. The API is
**ucsd+ops-restricted** at the firewall (the nix module's `sourcedPorts`) and
OIDC-gated for humans; this cert is the machine identity. No secret in tfvars.

## Apply

Via the control node, in dependency order (`openbao` first — it mints the AppRoles;
`incus` after the platform host is up):

```sh
TOFU_TARGETS="incus" ./deploy/deploy-tofu.sh
```

State is local + encrypted on krg-deploy (ADR 0005), same as the other targets. The
`tenants` map is empty by default, so this is **inert until tenants are declared** and
the `krg-nat` host + trust cert exist.

## Status / bring-up gates

- **Provider-attribute verification** — written against the `lxc/incus` provider
  schema and `tofu validate`-clean, but not yet applied against a live server (the
  `krg-nat` host is being provisioned). Verify on first `plan` like the e4e-nas target.
- **Golden-template image** — instances are `image`-gated and stay empty until the
  hardened template (AD-join, key-only SSH, auto-upgrade, monitoring, central logging —
  ADR 0017 §7) is published. Boundary (project + quota + profile + network) applies now.
- **Edge ingress route** — egress NAT is automatic; an edge reaching an instance needs
  the ingress path settled at bring-up (see the `krg-nat` host config).
