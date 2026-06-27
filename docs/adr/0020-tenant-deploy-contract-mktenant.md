# 0020. Tenant deploy contract — krg-infra exposes `lib.mkTenant`; tenant repos consume it to declare their deploy target

**Status:** Accepted · **Date:** 2026-06-25

## Context

[ADR 0017](0017-incus-nat-self-serve-platform.md) established **repo-owns-deploy** —
admins provision the boundary, the owning team manages the interior — but left the
*concrete onboarding mechanism* open: how does a tenant repo actually declare itself and
deploy the lab's blessed way? Without a contract, each tenant reinvents its deploy
(drift, inconsistency, copy-paste), or the boundary/interior split quietly blurs.

Nix flakes let one flake consume another's outputs, and krg-infra is already a flake. So
a tenant repo can **pin krg-infra as an input and consume a tenant-facing surface** to
define its deploy target — the typed, DRY realization of repo-owns-deploy.

## Decision

### 1. krg-infra exposes a narrow, stable, tenant-facing surface

A `lib.mkTenant` helper (plus `nixosModules.tenant` and a flake `template`). This is a
**versioned API/contract**, deliberately *not* krg-infra's internals — a tenant must be
able to evaluate it without dragging in host configs or secrets.

### 2. A tenant repo pins krg-infra and declares its deploy target

```nix
# <project>/flake.nix
inputs.krg-infra.url = "github:KastnerRG/krg-infra";   # pinned rev = stable contract
# ...
krgTenant = krg-infra.lib.mkTenant {
  name      = "fishsense";
  zone      = "e4e";                       # → routed by the e4e-prod edge
  hostname  = "fishsense.e4e.ucsd.edu";    # request
  sso.group = "fishsense";                 # request
  compose   = ./deploy/compose.yml;        # interior, tenant-owned
  resources = { cpu = 4; ram = "8G"; };    # request
};
```

The tenant's Incus instance may itself be a `nixosConfiguration` importing
`krg-infra.nixosModules.tenant`, so "the project flake defines its deploy target" is
literally true — the instance is built from the project's own flake.

### 3. Declaration vs provisioning — the trust split is preserved in the field set

`mkTenant`'s inputs are split, and the split is load-bearing (ADR 0017 §2):

- **Interior — tenant-owned, authoritative:** `compose`, image, deploy cadence. Shipped
  by the tenant's runner on merged `auto-deploy/*` PRs.
- **Boundary — requests, admin-provisioned, NOT self-granted:** `hostname`/CNAME, edge
  `zone`/route, `sso.group`, the OpenBao AppRole, `resources`/quota, the Incus instance
  slot. The `mkTenant` declaration is a **spec**; an admin **provisions it via
  `terraform/incus/`** (the Incus-provider root module, ADR-0005-style — projects /
  network / instances / quotas), so the boundary is `tofu`-reconciled state, exactly as
  `terraform/openbao` reconciles OpenBao. The tenant's spec reaches it as a reviewed PR /
  a pinned spec output. **A tenant cannot self-grant a boundary** — otherwise this
  re-creates the self-serve *services* that ADR 0017 rejected.

### 4. The contract carries the baseline + the deploy machinery

Consuming `mkTenant` / `nixosModules.tenant` gives a tenant the lab baseline (AD-join,
OEC where persistent per [ADR 0019]/[ADR 0017] §7, vault-agent, the repo-scoped runner
wiring, the edge re-encrypt cert) and a deploy entrypoint (`nix run .#deploy`) that wraps
the lab's flow — so tenants inherit conventions instead of reinventing them.

### 5. Coupling is managed as a versioned API

Tenants **pin a krg-infra rev**, so a deploy-contract change is an explicit bump, not a
surprise. The interface is kept **narrow and stable**; breaking changes are contract
versions. The exposed surface stays **minimal and secret-free** (a tenant never needs
fabricant's config to deploy).

## Consequences

- **Concrete onboarding for ADR 0017's repo-owns-deploy:** a tenant repo = pin krg-infra
  + one `mkTenant` declaration + its compose. The mechanism 0017 was missing.
- **The boundary stays admin-provisioned** (trust model intact); the tenant's declaration
  is a reviewed spec, not a self-service grab.
- **Two tenant shapes** are served by one contract: NixOS-instance tenants (import
  `nixosModules.tenant`) and compose-app tenants (a minimal NixOS instance + repo-owns
  -deploy compose, e.g. fishsense).
- **Version coupling:** tenants bump krg-infra to pick up contract changes — bounded by
  the narrow stable interface.
- **Depends on the platform existing:** this is the *contract*; it is buildable once
  ADR 0017's Incus platform + deploy mechanism land. Net-new in krg-infra: the
  `lib.mkTenant` output, the flake `template`, and the admin-side spec→provision path.

Related: [ADR 0001](0001-iac-source-of-truth.md) (git as source of truth),
[ADR 0005](0005-repo-integration-opentofu-krg-deploy.md) (deploy / krg-deploy),
[ADR 0008](0008-e4e-prod-tenant-platform.md) (tenants; repo-owns-deploy),
[ADR 0009](0009-lab-internal-pki-ad.md) (PKI / per-tenant AppRole),
[ADR 0017](0017-incus-nat-self-serve-platform.md) (the platform + provision/manage split
this concretizes), [ADR 0019](0019-proxmox-to-incus-migration.md) (the cluster tenants
deploy onto).
