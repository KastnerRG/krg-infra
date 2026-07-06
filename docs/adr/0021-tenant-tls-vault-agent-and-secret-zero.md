# 0021. Tenant TLS via in-instance vault-agent, and secret-zero delivery into Incus instances

**Status:** Accepted · **Date:** 2026-07-05

## Context

[ADR 0017](0017-incus-nat-self-serve-platform.md) settled the ingress path: the public zone
edge (e4e-prod / krg-prod Traefik) terminates public TLS and **re-encrypts** to a tenant
instance's inner Traefik, verifying the tenant's `tenant-internal` server cert (`<tenant>.vm`)
by chain against the fleet CA. [ADR 0020](0020-tenant-deploy-contract-mktenant.md) settled the
deploy contract (`lib.mkTenant` / `nixosModules.tenant`). The fishsense bring-up (tenant #1)
proved the whole admin boundary on real hardware — VM from the golden template, ingress
`incus_network_forward`, and a production LE cert at the edge (2026-07-05).

But the seam that makes re-encrypt actually work was left **deliberately unwired**
(`nix/modules/tenant.nix` flags it): the in-instance agent that mints `<tenant>.vm`. Two
things were missing:

1. **The cert itself.** The `tenant-internal` PKI role (`terraform/openbao/pki.tf`) and the
   per-tenant AppRole + policy (`terraform/openbao/tenants.tf`, granting
   `pki_int/issue/tenant-internal` and read of `secret/tenants/<name>/*`) both exist. What was
   missing is the runtime rendering — a `krg.vaultAgent` wiring in the tenant module. Until it
   lands, the tenant must hand-place `<tenant>.vm.{crt,key}`, which is exactly the drift the
   platform exists to remove.

2. **Secret-zero into the instance.** `krg.vaultAgent` authenticates with an AppRole role-id +
   secret-id that must be on-box before it runs. The existing staging path
   (`deploy/deploy-nixos.sh`) mints a fresh secret-id per deploy and pushes it over **ssh** —
   but that only works for **fleet hosts krg-deploy connects to directly**. A tenant instance
   is (a) on the Incus internal NAT (no public ssh) and (b) converged by the **tenant's own
   runner** (repo-owns-deploy), not by krg-deploy's `deploy-nixos.sh`. And the tenant **must
   not** mint its own secret-id — that would be self-granting a credential the admin owns
   (ADR 0020 §3). ADR 0017 §7 explicitly gated **persistent** instances on
   *secret-zero-into-persistent-instances*; fishsense is persistent and forces the decision.

## Decision

### 1. The tenant module renders `<tenant>.vm` via `krg.vaultAgent`

`nixosModules.tenant`, for a tenant with a compose interior, enables `krg.vaultAgent` with
`roleName = "tenant-${name}"` (matching the tofu AppRole) and renders the `tenant-internal`
cert to `/run/tenant/tls/${name}.vm.{crt,key}` (tmpfs; dirPerms `0755` so the inner-Traefik
container can traverse to read it). The inner Traefik bind-mounts `/run/tenant/tls` and serves
`<tenant>.vm`; the edge re-encrypt verifies it by chain. Fail-closed is inherited: a sealed or
unreachable OpenBao takes the stack down rather than serving a bad/absent cert.

### 2. cert and key come from a single issuance

`pki_int/issue/tenant-internal` (CN=`<tenant>.vm`) is one write that returns cert + key + chain
together; they must be split into separate files **without** re-issuing (a second issue yields a
non-matching key). Primary approach: two `krg.vaultAgent` renders with **identical** issue args
(consul-template dedups the PKI dependency within a run → one issuance, consistent cert/key) —
crt = `certificate` + `issuing_ca`, key = `private_key`. If the openbao-agent fork does not
dedup the write, fall back to one render of the raw JSON bundle plus a split step. A
`reloadCommand` restarts the inner Traefik on rotation.

### 3. Secret-zero is pushed by krg-deploy via `incus file push` at provision (option A)

After `tofu apply` creates a tenant instance, **krg-deploy** mints a fresh `tenant-<name>`
secret-id (it already holds `auth/approle/role/+/secret-id` and reads the role-id) and pushes
role-id + secret-id **into the instance** with `incus file push --project <name> …
<name>/var/lib/krg/openbao-agent/` (transport through krg-nat, using the same PKI-minted incus
client cert the tofu layer uses). This is the **same mint-fresh-per-provision model** as the
fleet ssh path — only the transport changes (ssh → `incus file push`), so no new trust or new
secret-at-rest. The tenant never sees a minting capability; it receives only its own
already-scoped credential.

Rejected alternatives for §3:
- **B — per-instance bootstrap share** krg-deploy writes and the instance reads on boot: more
  moving parts (a managed volume + a read-once boot unit) for no extra safety over A.
- **C — response-wrapped secret-id via incus cloud-init/config at create**, unwrapped by the
  agent: the cleanest crypto (single-use wrapped token, TTL-bounded) but new machinery; kept as
  the upgrade path if push-at-provision proves too coupled to the apply.

### 4. This opens the persistent-instance secret-zero path (ADR 0017 §7)

Accepting §3 lifts the ADR 0017 §7 gate for **persistent** tenant instances. Ephemeral
self-serve VMs still get a template-issued **write-only** push identity (0017 §7) and are out of
scope here. Renewal: the secret-id is re-pushed on each admin re-provision / a krg-deploy timer;
the rendered cert re-issues on the agent's schedule well inside its 30-day TTL.

## Consequences

- **fishsense goes end-to-end** once §1–§3 land: the inner Traefik serves `fishsense.vm` from
  vault-agent, the edge re-encrypt verifies by chain, and `https://fishsense.e4e.ucsd.edu`
  routes to the app. The hand-off's manual `deploy/tls/` step is deleted (mount becomes
  `/run/tenant/tls`).
- **Phasing:** PR 1 = §1+§2 (nix wiring + render/split), testable with a manually-staged
  secret-zero. PR 2 = §3 (the delivery), the gate-opener. Then update the hand-off compose mount.
- **Blast radius stays per-tenant:** a compromised instance can mint only its own `<tenant>.vm`
  and read only its own KV (the AppRole policy already scopes this); secret-zero is a fresh,
  narrowly-scoped secret-id, never a minting capability.
- **New coupling:** the provision flow (krg-deploy) now has a post-`tofu apply` step per exposed
  tenant. It is idempotent (re-push overwrites) and fail-closed (no secret-zero → agent fails →
  stack down, never up-with-bad-cert).
- Supersedes the "hand-place `<tenant>.vm`" interim documented in
  `docs/handoff/fishsense-lite/HANDOFF.md`.
