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
- The **server** direction is a real **pin**, not TOFU: `krg-nat-server.crt` in this
  directory is krg-nat's Incus server certificate, committed to git, and deploy-tofu.sh
  copies it to `servercerts/krg-nat.crt` in that same ephemeral dir. Required, not
  cosmetic — Incus self-signs with SAN `DNS:krg-nat` **only**, so dialing
  `krg-nat.ucsd.edu` fails hostname verification unless the cert is pinned (the incus
  client lib takes TLS `ServerName` from the pinned cert's first DNS name).
  `accept_remote_certificate` is left on as a backstop but does **not** cover this case.

  Refresh the pin if the daemon ever regenerates its cert (host rebuild, wiped
  `/var/lib/incus`) — the symptom is a `tofu apply incus` failing with
  `x509: certificate is valid for krg-nat, not krg-nat.ucsd.edu`:

  ```sh
  ssh krg-admin@krg-nat.ucsd.edu cat /var/lib/incus/server.crt \
    > terraform/incus/krg-nat-server.crt
  ```

  *Follow-up:* issuing the **server** cert from the fleet PKI as well (SANs for both
  names, like every other fleet service) would retire the pin entirely.

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
- **Edge ingress route** — SETTLED (a proxy device on `incus_instance`). Egress NAT is
  automatic; INGRESS is an Incus **proxy device** listening on `incus_host_ip:<edge_port>`
  (bind=host) that forwards to the instance's inner service (`127.0.0.1:443`). The zone
  edge dials `incus_host_ip:<edge_port>` (the `tenant_edge_backends` output) and
  re-encrypts. Chosen over an L3 route (Incus masquerades the return path — validated
  on-box), an `incus_network_forward` (its DNAT only fires host-locally — external edges
  saw the port filtered, validated on-box), and a shared bridge (Proxmox-dependent).
  Expose a tenant with `edge_port` (in `krg.incus`'s reserved 30000-30999 range).
