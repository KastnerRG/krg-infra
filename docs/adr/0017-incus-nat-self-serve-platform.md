# 0017. Self-serve VMs + tenant services on an internal Incus/NAT platform — re-realizing 0008

**Status:** Accepted · **Date:** 2026-06-25

> **Re-realizes [ADR 0008](0008-e4e-prod-tenant-platform.md).** 0008's *architecture*
> — repo-owns-deploy, the edge (LE-terminate + re-encrypt over OpenBao PKI), the
> provision/manage split, the pluggable `isolation` knob — stands and is reaffirmed.
> Its *mechanism* — nested `microvm.nix` guests, the `krg.tenants` flake module, a
> per-platform public-IP edge — is retired in favour of an Incus platform on an
> internal NAT, with a new self-serve VM tier and per-DNS-zone edges. microVMs are
> kept *in reserve* (see "When 0008's mechanism still wins"). This also amends
> [ADR 0016](0016-developed-apps-are-one-trust-tier.md) (§"Consequences").

## Context

The lab must host a mix of workloads under [ADR 0001](0001-iac-source-of-truth.md)
without recreating the failure that started the rebuild — an **unmanaged box on the
network, reached via a compromised credential**:

- **self-serve researcher compute** — people want their own boxes, fast, no operator
  in the loop;
- **team-developed services** — roster, fishsense, smartfin: the owning team ships
  continuously;
- **operated third-party apps** — Authentik, Grafana, Outline, MLflow…

[ADR 0008](0008-e4e-prod-tenant-platform.md) solved only the *service* slice, with
nested microVMs declared in the `krg.tenants` flake (operator-provisioned, no
self-serve) and a per-platform public-IP edge. Several constraints have since
firmed up that 0008 didn't account for:

- **Self-serve VM creation is a requirement**, not a nicety.
- **Provision ≠ manage.** Admins must own the *boundary* of a service; the owning
  team must own its *interior* (the fishsense students run fishsense — admins do not).
- **An internal NAT**, to stop paying UCSD for a public IP per machine and to
  collapse the flat-public attack surface ([[sealab-flat-public-no-nat]]). The NAT is
  **internal-only**.
- **UCSD DNS gives specific CNAMEs only — no wildcards — and only to public IPs.**
- **Long-term direction is Incus** + the [[nix-everything-north-star]] (fold the
  hypervisor tier into the flake).
- **Threat model:** tenants are semi-trusted, but the lab's actual incident was a
  *compromised credential* — so "internal-only" does **not** neutralise an attacker
  who is already authenticated. Kernel-level isolation still matters in that case.

## Decision

### 1. Three tiers, distinguished by who manages the interior

| Tier | Provisioned by | Interior managed by | Example |
|---|---|---|---|
| **Self-serve VM** | the user (self-serve) | the user | a dev / compute sandbox |
| **Tenant service** | **admin** (IaC boundary) | **the owning team** (repo-owns-deploy) | fishsense, roster |
| **Operated app** | admin (IaC) | admin (pinned, operated) | Authentik, Grafana |

### 2. Admins provision boundaries; owners manage interiors

The line is **blast radius**. The admin owns everything that touches shared
infrastructure or the security boundary — the edge route, the CNAME, the cert, SSO,
isolation, the resource quota, the repo-scoped-runner registration, the OpenBao
AppRole. The owner owns everything confined to the slot — the app, its compose, its
image, its deploy cadence. **Self-serve VMs are simply the tier where the owner
provisions their own (internal, unexposed) boundary too.** "Standing up a service"
(provisioning) is always an admin act; *managing* a service is never one.

### 3. Substrate — Incus, managed by NixOS; phase 1 nested in Proxmox, phase 2 bare metal

Incus is the platform (projects = tenancy, managed network = NAT, profiles+images =
the baseline, OIDC = auth); **NixOS manages the Incus host** (`virtualisation.incus`, a
flake config). So this is *Incus the tool, nix the management* — not an abandonment of
the lab's nix competence. The **boundary is IaC via `terraform/incus/`** — a new
ADR-0005-style per-target root module (Incus provider: projects / managed network /
profiles / instances / quotas) reconciled by `tofu plan` exactly as `terraform/openbao`
reconciles OpenBao. This is what makes "git is truth" hold on the boundary side, and it
maps 1:1 onto the §2 (and [ADR 0020](0020-tenant-deploy-contract-mktenant.md))
provision-vs-manage split.

- **Phase 1** — a NixOS VM on the current Proxmox host runs Incus. **Justified on its
  own merits** (self-serve + unified tenancy + no hand-rolled `krg-nat` box), so the
  decision does not hinge on phase 2. Networking: instances bridged onto an
  internal-only Proxmox bridge the edges also touch (simple reachability; egress SNAT
  once). Simple storage backend — **no ZFS-on-ZFS** ([ADR 0004](0004-vm-disk-io-budget.md)).
- **Phase 2** — Incus on bare metal (new host, or convert fabricant once the tier
  follows). Same flake module + Terraform config re-apply; instances move via
  `incus move` / cluster-evacuate; switch to the managed-NAT/OVN network + a real ZFS
  pool. **Now the hypervisor tier is in the flake** — the [[nix-everything-north-star]]
  gate opens. Upside, not the premise.

The config is portable across the move, so the nested phase is throwaway substrate,
not paid-for-twice.

### 4. Isolation by trust — untrusted/self-serve = VM, not container (load-bearing)

Incus offers a container↔VM dial; we set it by trust, **not** by density:

- **Self-serve and any untrusted tenant get a full Incus VM** (separate kernel). This
  contains a *compromised account* — the lab's real threat — where a shared-kernel
  container would let one kernel LPE escape to the host (in phase 2, the host running
  everything). We deliberately **do not** take the container density shortcut for
  untrusted workloads.
- **Containers are reserved for admin-operated/trusted instances**, where the admin
  owns the interior and the shared-kernel risk is admin-accepted, not attacker-exposed.

0008's `isolation` knob survives as `container | VM`, with `microvm.nix` held in
reserve for a genuinely *hostile* tenant (cloud-hypervisor's strong-isolation-at-low-
overhead profile — the one case where 0008's mechanism still wins outright).

### 5. Edges are per DNS zone — krg-prod and e4e-prod

The no-wildcard, CNAME-to-public-IP-only constraint *mandates* two public edges, and
gives them a principled (not trust-based) reason to exist: a `*.krg.ucsd.edu` name can
only point at krg-prod's IP, a `*.e4e.ucsd.edu` name at e4e-prod's.

- **krg-prod** owns ingress + LE issuance for the krg zone; **e4e-prod** for the e4e
  zone. Independent ACME clients → independent cert budgets/blast-radii.
- **HTTP-01 per explicit name** (the CNAME set *is* the allow-list — no wildcard, no
  on-demand/catch-all TLS, preserving 0008's issuance invariant).
- The edge **re-encrypts** to internal backends over OpenBao PKI ([ADR 0009](0009-lab-internal-pki-ad.md)),
  or plain on the trusted internal segment (opt-in re-encrypt per service).
- **Keystones co-locate on the edges** — Authentik (the edge's forward-auth depends on
  it) and Traefik *are* the front door. Other operated apps and tenant services are
  internal Incus backends the edge routes to.

There is **no dedicated tenant-platform host.** Tenants are Incus instances on the
internal NAT, reached publicly (when at all) through whichever zone edge owns their
name. `krg-nat`-as-a-box dissolves: egress NAT is the Incus managed network; ingress
is the edges.

### 6. Public exposure is admin-gated, per name

Self-serve gets you an internal box at its KRG.LOCAL/Incus DNS name. Making anything
public is an **admin IaC act** — a specific CNAME ticket + an edge route + SSO wiring.
Self-serve never touches routing, certs, or exposure, so the entire public surface
stays admin-controlled. The per-name gate sits exactly where the scarce resource
(public names) actually is.

### 7. Guardrails on the self-serve carve-out — and OEC follows persistence, not location

A self-serve VM interior is out of krg-infra IaC (user-owned, like `/home`) — but it
is *not* an unmanaged box:

- **Born from the hardened template** — AD-join, key-only SSH, auto-upgrade, monitoring,
  in-guest firewall + inter-tenant segmentation, central logging. Patched and visible by
  construction.
- **Internal-only and routes-to-nothing** until an admin exposes it. By definition not
  a *service*.
- **TTL/GC is enforced, not advisory.** Ephemeral VMs are hard-reaped / rebuilt from the
  golden template — both hygiene *and* the compliance justification below: a sandbox
  that never dies would be a gap, so longevity is not something you drift into, it is a
  deliberate **conversion to a persistent instance** (which brings OEC).
- **Never promoted in place.** Turning a sandbox into a service is always a *fresh IaC
  definition* (an operated/tenant instance) — the edge is never pointed at a drifted
  self-serve box.

**OEC (campus Qualys/Trellix) follows persistence, not NAT-membership.** Enrollment
creates a *tracked asset* that cannot be reliably de-registered on teardown, so
enrolling ephemeral VMs would churn orphaned assets we can't clean up. Therefore:

- **Ephemeral self-serve VMs are OEC-exempt** — a narrowly-scoped carve-out filed with
  ITS ([ADR 0006](0006-no-oec-on-dsm.md) pattern). Compensating controls: the enforced
  short lifespan + golden-template rebuild + auto-patching + segmentation + central
  logging.
- **Persistent VMs and all admin-provisioned service instances run full OEC** — enrolled
  once as stable assets, so cleanup is one-time, not churn.

This also **shrinks the secret-zero bootstrap**: an ephemeral VM exposes nothing and
holds no secrets, so it needs *neither* an OEC credentialed-installer broker *nor* a
vault-agent AppRole. Secret-zero-into-instances is thereby confined to *persistent,
admin-provisioned* instances — exactly the case where an admin can broker it.

### 8. Tenant services keep repo-owns-deploy

Admin provisions the Incus project + route + CNAME + SSO + repo-scoped runner +
AppRole + quota (krg-infra IaC); the owning team ships via merged `auto-deploy/*` PRs
(the tenant repo). IaC holds across **two sources** — krg-infra (the boundary) and the
tenant repo (the interior) — both reviewed, different owners. ADR 0001 is satisfied on
both sides of the seam.

## When 0008's mechanism still wins (recorded so it isn't re-litigated)

If tenants ever become **hostile** (not semi-trusted) **and** self-serve is dropped
**and** there is no appetite for a new platform — pure 0008 microVMs (uniform strong
isolation at low overhead, bespoke but nix-native) are the right answer. That is a
*different problem* than the one we have. The `microvm.nix`-in-reserve hook in §4
covers the narrower case of one hostile tenant on an otherwise Incus platform.

## Consequences

- **0008 is re-realized, not discarded:** its architecture is preserved; its
  realization (nested microvm.nix, `krg.tenants` flake module, per-platform public-IP
  edge) is retired. 0008 is marked superseded-in-mechanism.
- **[ADR 0016](0016-developed-apps-are-one-trust-tier.md) is amended:** its trust-axis
  correction (developed apps are one tier; krg-prod is the trust root, not an app host)
  **stands**; its host-layout conclusions are superseded here — **e4e-prod stays as the
  e4e edge** (the `krg-apps` rename is withdrawn), there is **no** `krg-apps` host, and
  tenants are Incus instances on the NAT fronted by per-zone edges.
- **Roster:** interim digest-pin on krg-prod closes [issue #288](https://github.com/KastnerRG/krg-infra/issues/288)
  now; strategic home is a **tenant service** on the Incus NAT, exposed via the krg-prod
  edge at `roster.krg.ucsd.edu`.
- **fishsense is the first tenant on the platform — no interim shortcut.** It blocks
  active research, so **phase-1 Incus standup is the critical path** to host it
  *properly*: an admin-provisioned Incus instance, repo-owns-deploy, behind the e4e-prod
  edge, vault-agent secrets. We explicitly **reject** the throwaway compose-on-e4e-prod
  stopgap (it would build fishsense twice) — ADR 0008's "do it right, not shortcuts."
  fishsense is the platform's forcing function, not an exception to it.
- **New self-serve VM tier** (quota'd Incus projects, OIDC→Authentik auth) that 0008
  lacked.
- **[ADR 0014](0014-proxmox-auth-ldap-outpost.md) becomes Proxmox-specific:** Incus
  authenticates via OIDC→Authentik directly; revisit if/when PVE is retired.
- **Threat-model note recorded:** containers are *not* used for untrusted tenants
  precisely because the lab's incident was a compromised credential.
- **Incus replaces Proxmox — not a new control-plane surface, a better one.** API access
  is UCSD-only (= Proxmox's today), so exposure is parity; but on the lab's actual threat
  (a compromised credential — the dictionary-attacked root SSH) it is a step *up*:
  OIDC→Authentik + per-project scoping confine a compromised self-serve credential to its
  own project. **≤ Proxmox exposure, > Proxmox containment.**
- **Execution note — source-restrict the Incus API.** "UCSD-only" only holds if the Incus
  API port is on `krg.firewall.sourcedPorts` (ucsd/ops), **not** the public list — like
  the service hosts. On the current flat-public sealab ([[sealab-flat-public-no-nat]])
  that firewall rule *is* the perimeter until the managed NAT lands.
- **OEC follows persistence:** ephemeral self-serve VMs are OEC-exempt (narrow ITS
  carve-out, [ADR 0006](0006-no-oec-on-dsm.md) pattern) and compensated by enforced
  TTL + template-rebuild + auto-patch + segmentation + central logging; persistent and
  service instances enroll. This **confines the secret-zero bootstrap** to persistent
  admin-provisioned instances. Owed: the ITS carve-out filing for the ephemeral class.
- **Tenant data backup = provision the pattern, manage the implementation.** The platform
  supplies a **Temporal-based backup template** (the lab's central Temporal cluster); each
  developer wires their own service's backup/restore into it. Consistent with §2 — the
  platform owns the pattern, the owner owns the implementation. (Ephemeral self-serve VMs
  hold no durable data by definition; this applies to persistent/service instances.)
- **Aggregate capacity governance is deferred (tracked).** Per-tenant quotas exist; a
  *fleet-level* cap so the sum of self-serve VMs cannot starve prod on the shared
  fabricant host (phase 1) is an open item, held for now per [ADR 0004](0004-vm-disk-io-budget.md).
- **Migrating the *existing* Proxmox fleet to Incus is a separate, larger effort** —
  rebuild-from-flake + data/storage migration + per-host network cutover, foundational
  hosts (krg-ldap, krg-vault) last and only behind HA. Captured in its own ADR. The
  platform here is *new* workload on Incus; moving krg-prod / krg-ldap / krg-vault / etc.
  is phase-2+.
- **Critical path:** phase-1 Incus (nested on fabricant) is not yet provisioned; standing
  it up is what unblocks fishsense, which lands as its first tenant. e4e-prod is
  provisioned as the e4e edge as part of this.

Related: [ADR 0001](0001-iac-source-of-truth.md) (git as source of truth),
[ADR 0004](0004-vm-disk-io-budget.md) (nested-IO/ZFS posture),
[ADR 0005](0005-repo-integration-opentofu-krg-deploy.md) (OpenTofu / krg-deploy),
[ADR 0008](0008-e4e-prod-tenant-platform.md) (re-realized here),
[ADR 0009](0009-lab-internal-pki-ad.md) (PKI + secret-zero reused),
[ADR 0013](0013-sso-authentik-front-door.md) (SSO front door),
[ADR 0014](0014-proxmox-auth-ldap-outpost.md) (PVE auth — now PVE-specific),
[ADR 0016](0016-developed-apps-are-one-trust-tier.md) (amended),
[ADR 0019](0019-proxmox-to-incus-migration.md) (the cluster this runs on),
[ADR 0020](0020-tenant-deploy-contract-mktenant.md) (the `lib.mkTenant` onboarding contract),
[issue #288](https://github.com/KastnerRG/krg-infra/issues/288).
