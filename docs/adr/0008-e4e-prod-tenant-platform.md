# 0008. e4e-prod is a multi-tenant platform for student-built projects — sealed microVM per tenant, repo-owned deploys

**Status:** Accepted · **Date:** 2026-06-17

## Context

`e4e-prod` was scaffolded as "the E4E project services host" — a `server`
profile VM mirroring `krg-prod`, with placeholder `default.nix` /
`hardware-configuration.nix` and a reserved IP (`137.110.161.107`). The first
workload to land is [`UCSD-E4E/fishsense-lite`](https://github.com/UCSD-E4E/fishsense-lite),
and its deployment model is the inversion of how `krg-prod` works: the
**application repo owns its own deployment** (its `deploy/compose.yml`, pushed by
a **self-hosted GitHub Actions runner** on merge of an `auto-deploy/*` PR), where
`krg-prod`'s stacks are Nix-store-defined and owned by *this* repo.

The deciding reframing during design: **fishsense is not the only thing here.**
e4e-prod is the home for *anything student-built* — fishsense, smartfin, and
future E4E projects each owning their own repo + deployment. That makes the
deliverable not "deploy fishsense" but "a multi-tenant substrate that N
student-owned projects plug into." The split mirrors the lab's operational
reality:

- **krg-prod** — staff-operated, lab-wide infrastructure (Traefik, Authentik,
  Grafana, Temporal, …); this repo owns every service definition.
- **e4e-prod** — student-operated project services; *each project's repo* owns
  its service definition and deploy, and the platform owns only the substrate
  around it.

This raises one problem above all others: a self-hosted runner executes whatever
its repo's workflow says, and to `docker compose up` it needs Docker access —
which on a shared rootful daemon is **host-root-equivalent**. With multiple
semi-trusted student repos on one host, the threat is real (mistakes /
noisy-neighbor in the near term; supply-chain / account compromise in the tail).
Doing this "right rather than taking shortcuts" (the explicit instruction) means
isolating tenants properly rather than relying on a deploy-discipline contract on
a shared daemon.

## Decision

### 1. Scope — per-platform; E4E first

The *module* is platform-generic (§6). The *first platform instance* hosts
student-built **E4E** (Engineers for Exploration) project services on the host
currently named `e4e-prod`; the reserved IP and the existing
[`applications_e4e.tf`](../../terraform/authentik/applications_e4e.tf) seed line
up with that. Scope is therefore **per-platform**, not module-wide: a second
platform for **all-KRG student** projects (`krg-student`) is anticipated and the
design accommodates it (tenants partitioned by `platform`, §6). If that sibling
lands, `e4e-prod` would be renamed `e4e-student` for symmetry. Lab-wide *tooling*
stays krg-prod's, distinct from either student platform.

### 2. One sealed microVM per tenant (the isolation boundary)

Each tenant runs in its own **microVM** ([microvm.nix](https://github.com/astro/microvm.nix)),
not a container on a shared daemon. Inside its VM a tenant has its own Docker +
repo-scoped runner + inner Traefik + Authentik outpost + vault-agent + its
**unmodified** `compose.yml`. The platform gives each VM a **hard CPU/RAM cap**
and a **dedicated ZFS volume** (a real boundary, not cgroups) for its
`DEPLOY_DIR` + Postgres data.

The governing property:

> **Runner-root is contained to the tenant's own VM.** A compromised or careless
> student deploy can wreck its own box and nothing else — not the host, not
> another tenant.

Tenant-from-tenant isolation comes from the VM boundary, so it holds regardless
of how TLS terminates (see §4).

**Realization:** tenants are **microvm.nix guests nested inside the e4e-prod
Proxmox guest** — e4e-prod stays a fabricant VM (sized generously; the
student-stack IO contention against fabricant's shared pool — [ADR 0004](0004-vm-disk-io-budget.md)
— is accepted and monitored rather than designed around with a dedicated host).
This keeps the single-platform-host model: the flake owns the whole fleet and
`krg.tenants.<name>` renders each VM. It requires **nested KVM** on fabricant
(`kvm_intel nested=1` + CPU type `host`). The host runs **ZFS-on-root** (single
pool, lz4, via disko) and carves the per-tenant **zvols** itself — self-contained,
so a new tenant is one `krg.tenants` declaration (not a Proxmox/ansible-layer disk
provision). Since e4e-prod sits on fabricant's ZFS this is **nested ZFS**, accepted
and tuned (small inner ARC / `primarycache=metadata`, single inner vdev), IO
monitored per [ADR 0004](0004-vm-disk-io-budget.md). Both the host and the tenant
VMs run **impermanent (ephemeral) root** (`modules/impermanence.nix`); only
`/persist` + the durable zvols survive, so drift or a compromise foothold in a VM
root resets on reboot — making "repair by redeploy" literal and contributing to
the runner-root containment above. Operator SSH is **break-glass, jump-through-the-host
only** (`:22` bridge-only, fleet keys, no AD; serial console as the deeper
fallback); tenant maintainers get no shell. The microVM **backend is
cloud-hypervisor**
(`krg.tenants` is still written backend-agnostic so it's swappable, but
cloud-hypervisor is the chosen default; QEMU is the compatibility fallback).

**Why cloud-hypervisor over the alternatives** (all three are crosvm-lineage):

- **firecracker** — excluded: no virtiofs, minimal device model, built for
  ephemeral functions — wrong fit for persistent Postgres/Docker stacks.
- **crosvm** — weighed (Google's VMM, the common ancestor; strong per-device
  minijail sandboxing). Excluded because its home turf is ChromeOS/Android
  desktop/mobile virtualization (GPU/wayland/interactive), not headless
  long-running server fleets, and the server-on-NixOS path is thinner. Its one
  real edge — guest→VMM-escape sandboxing — is tail-risk for *our* threat model
  (the VM is already the tenant boundary; tenants are semi-trusted, not hostile)
  and largely covered by cloud-hypervisor's seccomp.
- **cloud-hypervisor** — chosen: the same crosvm DNA *re-targeted at
  long-running cloud/server workloads* (modern virtio, hotplug, low overhead,
  virtiofs + virtio-blk + TAP), with first-class microvm.nix + NixOS gravity for
  headless server guests.

### 3. Repo-owns-deployment, under a mandatory contract

The tenant repo owns its compose and pushes it via a **repo-scoped** self-hosted
runner (never org-scoped — only that repo may target it) running as a
**dedicated `github-runner` user** *inside the VM*. Required of every tenant:
build/test on GitHub-hosted runners; the self-hosted runner only runs
`docker compose pull && up` on **merged `auto-deploy/*` PRs** (never arbitrary
contributor pushes); branch protection + review gates merges to `main`. The
trust boundary is therefore "people who can merge a project's `main`," confined
to that project's VM.

The runner's registration credential is a **GitHub App** (one per GitHub org —
`UCSD-E4E`, `KastnerRG` — installed on the tenant repos; key in OpenBao, a short-
lived registration token minted in-VM, **no long-lived PATs**). The only
operator-placed secret is the per-tenant AppRole `secret_id` (secret-zero); the
rest is vault-agent-rendered. **krg-deploy migrates to this same pattern**,
retiring its deferred hand-placed `github-runner-token` file.

### 4. Edge: LE-terminate at the platform, re-encrypt to tenants over OpenBao PKI

A **single platform-owned edge Traefik** on the e4e-prod host:

- terminates **public TLS** with Let's Encrypt certificates — it is the **sole,
  controlled ACME client** on the platform;
- routes each tenant's subdomain subtree to that tenant's VM — **one stable rule
  per tenant covering the apex label *and* every name beneath it**,
  `HostRegexp(`^(.+\.)?<subtree>$`)`. The apex matters: `fishsense.e4e.ucsd.edu`
  (the web portal) sits under `*.e4e.ucsd.edu`, **not** `*.fishsense.e4e.ucsd.edu`,
  so a bare `*.fishsense…` wildcard would miss it. Tenants thus partition the
  shared `*.e4e.ucsd.edu` space: `fishsense.*` → fishsense VM, `smartfin.*` →
  smartfin VM, each owning its label apex + subtree;
- **re-encrypts** the hop to each tenant VM over **OpenBao PKI** (internal CA,
  short-TTL certs auto-rotated by the VM's vault-agent), optionally **mTLS** so a
  VM backend accepts connections only from the edge.

**The public LE private key lives in exactly one place** (the edge), never copied
into tenant VMs. Tenants hold only cheap, short-lived internal-PKI certs.

Two load-bearing invariants (see §"Issuance invariant"):

> **The edge issues only from an explicit, declared hostname list. Traefik
> on-demand / catch-all TLS is forbidden.** Students never run ACME at all.

**Auth stays in the VM, not at the edge.** Per-route auth policy lives in the
tenant's compose labels (`authentik@docker` per router), which the edge can't
see — so the edge does TLS-terminate + route + re-encrypt only, and the
**per-tenant Authentik outpost stays inside the VM**, keeping the tenant's
compose unmodified. (A future opt-in "auth the whole subtree at the edge" knob is
possible for a tenant that wants uniform auth; not the default.)

### 5. Central services stay on krg-prod (not duplicated on e4e-prod)

- **Authentik** — the server stays central on krg-prod. Each tenant VM runs a
  *proxy outpost* pointed at it.
- **Temporal** — the cluster stays central on krg-prod. fishsense's workers
  connect cross-host (its own `compose.temporal.yml` is dropped). This needs a
  `fishsense` namespace + client mTLS certs + cross-host gRPC on the krg-prod
  side.

### 6. `krg.tenants.<name>` is the abstraction (generic, multi-platform)

The module namespace is **`krg.tenants`, not `e4e.*`**. `krg.*` is the repo's
single option namespace — org-wide, not a host marker (`krg.scratch`,
`krg.localCache`, `krg.adClient` all run off krg-prod) — so an `e4e.*` namespace
would be the first non-`krg` option tree for a marginal signal, and worse, would
bake one platform's identity into a generic mechanism. E4E scope is expressed by
enablement + declarations (the repo's existing pattern: `applications_e4e.tf`, the
`e4e-prod` host, `e4e-admin` — scope by site, one option tree), not by the prefix.

The module generates a tenant's microVM, dedicated user, ZFS volume + caps, the
runner, the vault-agent render targets (per-tenant **OpenBao AppRole**), and the
edge's hostname→VM entry. `isolation` is a **pluggable knob** (`microvm` today).
**vault-agent from the start** (no pre-Vault `.secrets` interim).

**Multiple platforms, tenants partitioned across them.** The design is a
*per-platform instance*, not e4e-prod-specific. A host becomes a platform via
`krg.tenantPlatform = { enable = true; id = "<platform>"; }` and owns that
instance's edge Traefik, microVM fleet, cert-manager, and bridge — its own IP, LE
ACME client, and internal-CA client cert. Each entry in the shared `krg.tenants`
roster carries a `platform = "<id>"` field; a platform host instantiates only the
tenants whose `platform` matches its `id`, leaving the rest inert. So **two
platform hosts can run concurrently** — e.g. an `e4e-student` platform and a
`krg-student` platform — with tenants assigned to each by one field. Reassigning a
tenant is a one-field change (+ a DNS CNAME re-point + cert/zvol re-home, since
each platform has its own edge IP/cert). This is exactly why the module stays
generic.

### 7. We own both sides

This repo's substrate PRs **and** the coordinated `UCSD-E4E/fishsense-lite` PRs
(drop its Temporal → point at krg-prod; fix the stale `auth.fabricant` →
`auth.krg` OIDC issuer; set `DEPLOY_DIR`/`USER_ID`/`GROUP_ID`; bootstrap ops
dirs).

## Issuance invariant — why the edge can't be rate-limited by a tenant

The rate-limit fear (a student crash-loop burning the shared `ucsd.edu`
Let's Encrypt budget, or tripping the failed-validation block) is closed by
construction:

- **Students never run ACME.** They live in VMs that speak only internal OpenBao
  PKI; they hold no LE account, no DNS creds, no enabled ACME resolver.
- **Exactly one ACME client** exists (the edge), persistent + staging-first +
  backoff, issuing **one multi-SAN cert per tenant** renewed ~60-day — issuance
  happens on hostname-set change or renewal, never on a deploy.
- **Explicit-list issuance, never on-demand.** An unknown SNI matches no router →
  default cert served, **no issuance attempted**. This — not the absence of
  wildcard DNS — is the load-bearing guard: on-demand TLS would let a stranger
  hitting the edge IP with arbitrary SNIs trigger failing issuance attempts
  *regardless of DNS*. No-public-wildcard-DNS is real defense-in-depth, but the
  explicit list is what makes stranger-SNI-spam a no-op. (This is already
  krg-prod's posture; the design's job is to not regress it.)

The one residual we don't fully control: the LE limit is keyed on the registered
domain `ucsd.edu`, shared with all of campus. Multi-SAN + 60-day keeps our
footprint negligible (see "CA source" below for why LE, not InCommon).

## Why not the alternatives we considered

- **Shared rootful Docker + a deploy-discipline contract** (the v1 shortcut).
  Cheapest, and the contract is sound, but it leaves the Docker socket
  root-equivalent and gives no tenant-from-tenant boundary. Rejected per "do it
  right rather than shortcuts." The contract is kept anyway (§3) — it's free —
  just no longer the *only* control.
- **Rootless Docker per tenant.** Real isolation, NixOS-supported, but each
  rootless daemon has its own netns and can't share the platform ingress
  network — it fights the single-edge model.
- **SNI passthrough, tenant terminates public TLS in-VM.** Strongest
  "host-never-sees-plaintext," but it **distributes the public LE key into every
  VM** and needs per-tenant ACME or cert-delivery. The re-encrypt model (§4)
  keeps the public key in one place and uses idiomatic OpenBao PKI for the
  fan-out; "host sees plaintext in transit" is marginal because the host already
  owns every VM's lifecycle.
- **DNS-01 / wildcard certs.** We do **not** control DNS (records are individual
  CNAME tickets), so DNS-01 and wildcard certs are off the table. HTTP-01 +
  explicit multi-SAN lists it is.

## Consequences

- e4e-prod gains a per-tenant microVM fleet (microvm.nix as a flake input), a
  platform edge Traefik, and the `krg.tenants` module.
- **The internal CA already exists — reuse, don't rebuild.** The lab OpenBao PKI
  (`pki_root` → `pki_int`, #241) is generalized into a fleet CA with generic
  `host`/`user` issuing roles + **fleet-wide CA trust in `base.nix`** by #259, and
  the "vault-agent issues a TLS leaf from the PKI" pattern is proven by the waiter
  XRDP cert (#260: per-consumer AppRole → `pki_int/issue/host` → rendered to
  `/run`, secret_id on a persisted path). e4e-prod **reuses `pki_int/issue/host`**
  for tenant-VM inner-Traefik server certs and the existing `temporal-client`-style
  client-role pattern for the edge's mTLS leg. **Net-new is small:** per-tenant
  AppRoles + an edge client-cert role + vault-agent render targets — *not* a new
  CA. **This work stacks on #259** (fleet CA trust + the `host` role) and follows
  #260's pattern; see `docs/pki-ad-integration.md`.
- **Adding a hostname is a 3-actor act**, only the middle one automatable: CNAME
  ticket (external) → edge SAN added + re-issued (platform) → tenant adds the
  service+label (self-service in-VM). Routing stays stable (subtree match).
- **Blocker:** the e4e-prod VM is not yet provisioned, so all of this is offline
  declarative work (`nix flake check`-able) until the host boots and a real
  `hardware-configuration.nix` is generated.
- AD domain-join for e4e-prod remains pending (tenant VMs themselves are
  appliance-like and need not AD-join; revisit per-VM monitoring).
- The `isolation` knob means this ADR is **not** a forever-commitment to
  microVMs for every tenant — it's the default boundary, overridable per tenant.

## CA source — Let's Encrypt (InCommon rejected)

The CA is **Let's Encrypt**. UCSD's **InCommon/Sectigo** path was considered and
**rejected**: campus InCommon certs traditionally require **manual approval per
certificate** — fundamentally incompatible with an automated edge that issues and
renews multi-SAN certs on a ~60-day cadence with no human in the loop. (This is
why the lab has historically avoided InCommon.)

The accepted residual: LE's "certificates per registered domain" limit is keyed
on `ucsd.edu`, shared with all of campus. The issuance invariant above keeps our
footprint negligible (one central client, one multi-SAN cert per tenant, 60-day
renewal, never on-demand). The cert-manager is still written **CA-agnostic** (any
ACME directory URL), so if UCSD ever offers an **auto-approved** Sectigo ACME
endpoint, switching is a config change — but manual-approval InCommon is not a
candidate.

Related: ADR 0001 (git as source of truth), ADR 0005 (repo integration /
OpenTofu / krg-deploy as control node), `docs/e4e-prod-tenant-platform.md`
(the companion design doc), `docs/pki-ad-integration.md` (the lab PKI this builds
on — #241/#259, vault-agent issuance pattern #260), `docs/krg-prod-iac.md`.
