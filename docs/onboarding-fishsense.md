# Onboarding fishsense — the first Incus-platform tenant

fishsense-lite ([UCSD-E4E/fishsense-lite](https://github.com/UCSD-E4E/fishsense-lite))
is **tenant #1** on the Incus platform ([ADR 0017](adr/0017-incus-nat-self-serve-platform.md),
[ADR 0020](adr/0020-tenant-deploy-contract-mktenant.md)). It is the platform's forcing
function, not an exception to it — no throwaway compose-on-e4e-prod stopgap (that would
build fishsense twice). This runbook is the **end-to-end execution plan**: the tenant
declaration the fishsense repo owns, the boundary an admin provisions, and the bring-up
sequence.

It exercises every piece of the platform built across the Incus track:

| Piece | PR | fishsense's use |
|---|---|---|
| OpenBao per-tenant AppRole + `tenant-internal` PKI | #374 | `tenant-fishsense` AppRole; mints its `fishsense.vm` cert |
| Incus host substrate (`krg.incus` / `krg-nat`) | #375 | runs the fishsense instance |
| Tenancy boundary (`terraform/incus`) | #376 | the `fishsense` project + quota + instance |
| Deploy contract (`lib.mkTenant`) | #377 | the declaration below |
| Zone edge (`krg.edge` on e4e-prod) | #378 | routes `*.fishsense.e4e.ucsd.edu` → the instance |

> **Status / gates.** This runbook is executable once: (1) the platform PRs above merge
> to `main`; (2) `krg-nat` is provisioned (a nested VM on fabricant, **nested virt on** —
> ADR 0017 critical path); (3) the golden-template image exists — **DONE**: `krg-golden`,
> built from `nixosConfigurations.krg-golden` + published by CD ([ADR 0017 §7](adr/0017-incus-nat-self-serve-platform.md));
> (4) the CNAMEs are published (we request them one at a time); (5) the GitHub App for the
> repo-scoped runner is created (the deferred krg-deploy item). Each step below flags which
> gate it needs.

---

## 1. The declaration — `fishsense-lite` owns this (interior)

In the tenant repo (`UCSD-E4E/fishsense-lite`), `flake.nix` pins krg-infra and declares
the deploy target via the contract. This is the **interior** — authoritative, shipped by
the team's runner.

```nix
# fishsense-lite/flake.nix
{
  inputs.krg-infra.url = "github:KastnerRG/krg-infra?dir=nix";  # pin a merged rev
  inputs.nixpkgs.follows = "krg-infra/nixpkgs";

  outputs = { self, krg-infra, nixpkgs }: let
    tenant = krg-infra.lib.mkTenant {
      name      = "fishsense";
      zone      = "e4e";                      # → fronted by the e4e-prod edge
      hostname  = "fishsense.e4e.ucsd.edu";   # request (apex; SANs in the edge route)
      sso.group = "fishsense";                # AD group (auth is in-app today)
      resources = { cpu = 4; ram = "8GiB"; }; # request
      compose   = ./deploy/compose.yml;       # YOUR interior
      repo      = "UCSD-E4E/fishsense-lite";   # repo-scoped runner registers here
    };
  in {
    nixosConfigurations.fishsense = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ krg-infra.nixosModules.tenant { krg.tenant = tenant; } ./hardware-configuration.nix ];
    };
    krgTenant = tenant;   # admin reads .terraformTenant from this (step 2)
  };
}
```

`deploy/compose.yml` is the **unmodified project stack** plus an inner Traefik that serves
the `fishsense.vm` cert (vault-agent renders it from the tenant AppRole) and routes the
public names to the right container. The edge re-encrypts to this:

```
fishsense.e4e.ucsd.edu              → web portal   (fishsense-lite-web)
orchestrator.fishsense.e4e.ucsd.edu → API
analytics.fishsense.e4e.ucsd.edu    → superset
# api · web · workers · superset · postgres + inner traefik; workers reach krg-prod Temporal over gRPC
```

The runner does `docker compose up` on merged `auto-deploy/*` PRs from `/srv/fishsense`
(`DEPLOY_DIR`). Apex is load-bearing: `fishsense.e4e.ucsd.edu` sits under `*.e4e.ucsd.edu`,
so a single edge rule `HostRegexp(^(.+\.)?fishsense\.e4e\.ucsd\.edu$)` covers the apex **and**
every descendant — adding `newthing.fishsense.e4e.ucsd.edu` later is a one-line SAN
addition, no new edge rule.

---

## 2. The boundary — an admin provisions this (krg-infra)

The admin copies fishsense's projection straight into IaC. **The tenant cannot self-grant
any of this** (ADR 0020 §3).

**a. OpenBao** — `terraform/openbao` `var.tenants` (the AppRole + least-privilege policy,
#374):

```hcl
fishsense = { kv_prefix = "tenants/fishsense" }
```

**b. Incus boundary** — `terraform/incus` `var.tenants` (#376). This is exactly
`nix eval .#krgTenant.terraformTenant --json` from the tenant flake:

```hcl
fishsense = {
  zone      = "e4e"
  cpu       = 4
  memory    = "8GiB"
  disk      = "20GiB"           # raise if Postgres needs more
  isolation = "virtual-machine" # untrusted developed code = separate kernel (§4)
  image     = ""                # boundary-only start; set to "krg-golden" (published, gate 3) to boot the slot
  edge_port = 30443             # krg-nat port the e4e edge dials; a proxy device forwards it to the instance:443
}
```

**c. Edge route** — `e4e-prod` `krg.edge.routes` (#378). Needs the CNAMEs (gate 4); the
`backend` is `krg-nat:edge_port` (the ingress proxy device from 2b), not the instance address:

```nix
krg.edge.routes.fishsense = {
  subtree   = "fishsense.e4e.ucsd.edu";
  hostnames = [                              # the explicit LE SAN list
    "fishsense.e4e.ucsd.edu"
    "orchestrator.fishsense.e4e.ucsd.edu"
    "analytics.fishsense.e4e.ucsd.edu"
  ];
  backend   = "137.110.161.105:30443";       # krg-nat:edge_port — the ingress proxy device
                                             # forwards this to the instance's inner Traefik:443
                                             # (= terraform/incus output tenant_edge_backends.fishsense).
  # serverName defaults to "fishsense.vm"; reencrypt defaults true (verifies the
  # tenant-internal cert vs the fleet CA).
};
```

**d. CNAMEs to request** (gate 4 — one at a time): each → `e4e-prod.ucsd.edu`.

```
fishsense.e4e.ucsd.edu
orchestrator.fishsense.e4e.ucsd.edu
analytics.fishsense.e4e.ucsd.edu
```

---

## 3. The runner credential (gate 5)

The repo-scoped self-hosted runner registers to `UCSD-E4E/fishsense-lite` via a **GitHub
App** (one per GitHub org) — not a PAT. This is the deferred krg-deploy runner-token item;
fishsense is what forces it. The App's installation token is brokered into the instance's
`DEPLOY_DIR` (fail-closed), the runner re-registers on boot, and the same App fix lands for
krg-deploy at the same time (the original "we'll do an app and fix krg-deploy at the same
time").

---

## 4. Bring-up sequence

1. **Platform up** — merge #374–#378; provision `krg-nat` (gate 2); apply
   `TOFU_TARGETS="openbao incus"` so the AppRole + project/quota exist.
2. **Golden template** (gate 3, **DONE**) — the hardened `krg-golden` image is built +
   published by CD (`deploy/incus-publish-golden.sh`); set `image = "krg-golden"` in 2b;
   `tofu apply` `terraform/incus` → the fishsense instance boots from the template.
3. **Secrets** — seed `secret/tenants/fishsense/*`; the in-instance vault-agent (tenant
   AppRole) renders the `fishsense.vm` cert + app secrets.
4. **Runner** (gate 5) — create the GitHub App; the runner registers; a merged
   `auto-deploy/*` PR brings the compose up. Verify the inner Traefik serves `fishsense.vm`.
5. **Expose** (gate 4) — request the CNAMEs; add the edge route (2c) with the instance
   backend. Validate against LE **staging** first (`krg.edge.acme.staging = true`), confirm
   the chain, then switch to production issuance.
6. **Verify** — `https://fishsense.e4e.ucsd.edu` (web), `…/orchestrator` (API),
   `…/analytics` (superset); workers reach krg-prod Temporal; edge re-encrypt verifies the
   tenant cert by chain.

---

## Notes / follow-ups

- **SSO forward-auth** to krg-prod's central Authentik is a follow-up edge seam; fishsense
  auth is in-app today.
- **Backup** — wire fishsense's Postgres into the platform's Temporal-based backup template
  (ADR 0017 — platform owns the pattern, the team owns the implementation).
- **mkTenant SAN list** — the contract carries a single `hostname`; the extra public SANs
  (orchestrator/analytics) are set by the admin in the edge route from fishsense's
  onboarding request. A future contract bump could carry the full list.
