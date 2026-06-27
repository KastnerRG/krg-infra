# 0016. Developed apps are one trust tier (the tenant model); krg-prod is the trust root, not an app host

**Status:** Accepted · **Date:** 2026-06-25 · **§3–§5 superseded by [ADR 0017](0017-incus-nat-self-serve-platform.md) (2026-06-25, same-day)**

> **Revised same-day by the [ADR 0017](0017-incus-nat-self-serve-platform.md)
> synthesis.** The **trust-axis correction** (§1–§2 — developed apps are one tier;
> krg-prod is the trust root, not an app host; audience ≠ trust) is the durable
> contribution and **stands**. The **host-layout conclusions are superseded**: there is
> **no `krg-apps` host** (the §3 rename is withdrawn — e4e-prod stays as the e4e public
> edge), and tenants are not a dedicated platform host but **Incus instances on an
> internal NAT fronted by per-zone edges** (krg-prod / e4e-prod). §3–§5 are kept below,
> corrected, with the original proposal noted for the record.

## Context

[ADR 0008](0008-e4e-prod-tenant-platform.md) introduced the tenant platform with
a host split framed as a **trust** boundary:

- **krg-prod** — staff-operated, lab-wide infrastructure; *trusted*.
- **e4e-prod** — student-built E4E project services; *untrusted*.

That framing is wrong, and [E4E Roster V3](https://github.com/UCSD-E4E/E4E-Roster-V3)
is the case that exposes it. Roster runs on **krg-prod** — placed there because its
*audience* is lab-wide (all of KRG uses it, not just E4E) — yet it is deployed by a
hand-cloned git checkout updated with `git pull && systemctl restart`
([issue #288](https://github.com/KastnerRG/krg-infra/issues/288): a direct
[ADR 0001](0001-iac-source-of-truth.md) violation). It is an *application* parked in
the *trust root*, deployed by hand.

The original split collapses **two independent axes into one**:

- **Trust** — how much damage a bad deploy can do. Driven by *what runs the deploy*
  (a runner executing merged code is host-root-equivalent on a shared daemon) and
  *what credentials the app holds*.
- **Audience** — who *uses* the app: lab-wide vs a single E4E project.

`krg-prod = trusted` silently relabeled "lab-wide audience" as "trusted." But
roster's deploy runs merged code through a runner *exactly* as a student app does —
the only difference is *who merges* (lab staff vs students), a marginal trust delta,
not a category. Co-locating it with Authentik / Traefik / Grafana doesn't make it
trusted infrastructure; it smuggles an app into the trust root. Symmetrically,
"untrusted student" overstates the other side: a student app sealed in its own
microVM with a scoped AppRole is no more dangerous than roster. They are the **same
tier**.

Roster sharpens the point further: it holds the privileged **`svc_roster` AD bind**
and is the authority for human AD group membership
([ADR 0010](0010-active-directory-structure-as-iac.md) — humans are roster's). An app
that can *mutate the directory* is precisely the one you most want sealed in its own
VM with a scoped, vault-agent-rendered credential — not running on the same host as
the directory's relying parties. Roster being lab-wide is an argument **for** the
tenant model, not against it.

## Decision

### 1. The boundary is trust-root vs developed-app — not lab vs student

The fleet's deployment boundary is **operated infrastructure (the trust root)** vs
**developed application (runs a runner that deploys merged code)**:

- **krg-prod = the trust root.** Operated infrastructure only — Traefik, Authentik,
  Grafana, Temporal, and the lab-wide tooling this repo defines in the Nix store and
  pins. **No developed apps run on krg-prod.**
- **Developed apps = a single trust tier**, served by the **tenant model** of
  [ADR 0008](0008-e4e-prod-tenant-platform.md): an isolated instance per tenant
  (0008's microVM, re-realized as an Incus instance per [ADR 0017](0017-incus-nat-self-serve-platform.md)),
  repo-owns-deploy via a repo-scoped runner on merged `auto-deploy/*` PRs,
  edge-terminated TLS re-encrypted over OpenBao PKI, per-tenant AppRole,
  vault-agent-rendered secrets. Roster, fishsense, smartfin, and every future
  lab- or student-authored application are tenants here.

### 2. Audience (lab-wide vs project) is platform + SSO + DNS — not trust

Lab-wide vs E4E-project is a **sub-partition of "developed app,"** expressed by:

- **SSO scope** (lab-wide AD vs a project AD group) — who may log in;
- the **DNS zone** the name lives in (`roster.krg.ucsd.edu` vs
  `fishsense.e4e.ucsd.edu`) — which sets *which edge fronts it*.

None of these is a *host trust* boundary. **Per [ADR 0017](0017-incus-nat-self-serve-platform.md)
there are two edges, one per DNS zone** — krg-prod for `*.krg`, e4e-prod for `*.e4e` —
because UCSD issues only specific CNAMEs to specific public IPs (no wildcards), so a
krg name can only point at krg-prod's IP. The tenant *instance* is the
tenant-from-tenant boundary, so which edge fronts a tenant carries no isolation weight
— it is purely a DNS-zone routing fact. *(This corrects 0016's original "single edge
Traefik / multi-SAN" wording, which assumed one edge.)*

### 3. e4e-prod stays as the e4e edge (the `krg-apps` rename — withdrawn)

**Originally proposed here (withdrawn same-day):** rename `e4e-prod → krg-apps`, a
single "developed-application platform" host. [ADR 0017](0017-incus-nat-self-serve-platform.md)
overturned this. There is **no dedicated tenant-platform host** — tenants are Incus
instances on the internal NAT — and the no-wildcard / CNAME-to-a-specific-public-IP
constraint *requires* e4e-prod to keep its identity as the **e4e-zone edge** (a
`*.e4e.ucsd.edu` name can only point at its IP). So the fleet reads:

- **`krg-prod`** — trust root + the `*.krg.ucsd.edu` public edge.
- **`e4e-prod`** — the `*.e4e.ucsd.edu` public edge (**kept, not renamed**).

The reserved `.107` IP and `applications_e4e.tf` carry over unchanged; E4E is a
zone/audience the e4e-prod edge fronts, not a host identity. (The `krg.tenants` /
`krg.tenantPlatform` module namespace this section assumed is itself retired by 0017 in
favour of Incus projects.)

### 4. Tenants are Incus instances on a shared internal NAT — not a platform host

**Superseded by [ADR 0017](0017-incus-nat-self-serve-platform.md).** This section
originally argued for "one tenant-platform host now, split when driven." 0017 resolves
it differently and the "one or two platform hosts" question is **moot**: there is no
platform *host*. Tenants are Incus instances on a single internal-only NAT fabric,
fronted by the two per-zone edges (§3). The tenant-from-tenant boundary is the
per-tenant Incus instance — a **VM** for untrusted / self-serve tenants, a container
only for admin-operated ones (0017 §4) — and the krg-vs-e4e split is the per-zone edge,
not a host a tenant "lands on."

### 5. Roster migrates; interim fix closes ADR 0001 now

Roster's strategic home is a **tenant service** — admin-provisioned boundary, owning
team manages the interior (repo-owns-deploy) — running as an Incus instance on the
internal NAT and exposed through the **krg-prod edge** at `roster.krg.ucsd.edu` with
lab-wide SSO ([ADR 0017](0017-incus-nat-self-serve-platform.md); originally phrased
here as "a tenant on `krg-apps`").

Since the Incus platform is not yet provisioned and roster is a *currently running*
service, the immediate ADR 0001 fix (issue #288) is the lighter **pin-the-image-digest**
remediation on krg-prod: move the compose into the Nix store and reference a pinned
image, killing the on-box `git pull`. That is **not throwaway** — it removes the
hand-pull today — but it is explicitly an interim step toward the tenant model, not the
destination.

## Consequences

- **ADR 0008's trust framing is amended (this ADR's durable contribution).** The
  "krg-prod trusted / e4e-prod untrusted" *labeling* is corrected to trust-root vs
  developed-app, with audience as a separate axis. (0008's *realization* is separately
  retired by [ADR 0017](0017-incus-nat-self-serve-platform.md); 0008's anticipated
  `e4e-prod → e4e-student` rename and this ADR's proposed `e4e-prod → krg-apps` rename
  are **both** withdrawn — e4e-prod stays as the e4e edge.)
- **krg-prod's scope shrinks** to operated infrastructure + the trust root + the
  `*.krg.ucsd.edu` edge; roster (and any future app) leaves it as a *service*, not as a
  co-located stack.
- **Roster is a two-step migration:** (a) interim digest-pin on krg-prod to close
  issue #288, then (b) re-home as a tenant service on the Incus NAT, fronted by the
  krg-prod edge (ADR 0017).
- **No host rename happens.** e4e-prod is kept as the e4e-zone edge; the E4E terraform
  seeds (`applications_e4e.tf`, the `.107` IP) are unaffected.
- **"Lab-wide app" is no longer a reason to run on krg-prod.** New developed apps are
  admin-provisioned tenant services on the Incus NAT (ADR 0017); only operated
  infrastructure earns a krg-prod service definition.

Related: [ADR 0001](0001-iac-source-of-truth.md) (git as source of truth — the
violation this corrects), [ADR 0005](0005-repo-integration-opentofu-krg-deploy.md)
(repo integration / krg-deploy control node),
[ADR 0008](0008-e4e-prod-tenant-platform.md) (the tenant platform this amends),
[ADR 0009](0009-lab-internal-pki-ad.md) (PKI + per-host secret-zero the tenant model
reuses), [ADR 0010](0010-active-directory-structure-as-iac.md) (roster owns human AD
membership), [ADR 0013](0013-sso-authentik-front-door.md) (SSO front door),
[ADR 0017](0017-incus-nat-self-serve-platform.md) (the Incus/NAT synthesis that
supersedes §3–§5), [issue #288](https://github.com/KastnerRG/krg-infra/issues/288)
(roster ADR 0001 violation).
