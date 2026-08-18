# 0023. Tenant Temporal access — client-cert delivery (in-slot vault-agent + off-prem NRP)

**Status:** Proposed · **Date:** 2026-07-06

## Context

The krg-prod Temporal frontend (`krg-prod.ucsd.edu:7233`, raw gRPC) is **mTLS-only, public, and
reachable** from both an in-slot tenant worker (10.100.0.10, via egress NAT) and an off-prem NRP
worker — *"the cert is the access control, not the network"* (`ansible/.../krg-prod.fw`,
`compose.temporal.yml`). The per-tenant `fishsense` **namespace exists** (`terraform/temporal`).

The one missing thing is that a tenant **cannot obtain a `temporal-client` cert**:

- The per-tenant OpenBao AppRole grants only `pki_int/issue/tenant-internal` (the `<tenant>.vm`
  server cert, [ADR 0021](0021-tenant-tls-vault-agent-and-secret-zero.md)). Issuance of
  `temporal-client` is held only by the `krg-deploy` and `krg-prod` policies
  (`terraform/openbao/pki.tf`).
- `terraform/temporal/README.md` explicitly defers off-site/NRP worker-cert provisioning to a
  separate task. `docs/handoff/fishsense-lite/HANDOFF.md` §6 flags the same gap.

So mechanism + reachability are fully wired; **cert delivery to the tenant is the missing seam.**
There are two consumer shapes:

1. **In-slot workers** — on the Incus platform, already running the in-VM vault-agent (ADR 0021).
2. **Off-prem NRP workers** — on an NRP k8s cluster, off our OpenBao, deployed by a GitHub-hosted
   job with an NRP kubeconfig.

The `temporal-client` PKI role: `client_flag=true`, `allowed_domains = ["krg-deploy",
"temporal-worker", "temporal-ui"]`, `allow_subdomains=false`, **ttl 7d / max_ttl 30d**.

## Decision

### 1. A tenant *requests* Temporal via `mkTenant`; the admin grants it

`lib.mkTenant` gains an optional `temporal = { namespace = "fishsense"; }`. Setting it (a) gates
the in-slot render (§2), and (b) signals the admin to add the OpenBao grant (§2) and confirm the
namespace exists in `terraform/temporal`. Empty = no Temporal wiring (unchanged for tenants that
don't use it). The tenant **requests**; the admin **grants** — same split as every other boundary
(ADR 0020 §3).

### 2. In-slot workers — vault-agent renders `temporal-client`, exactly like `<tenant>.vm`

For a tenant that opted in (§1), extend its OpenBao policy (`terraform/openbao/tenants.tf`) with
`pki_int/issue/temporal-client`, and add a render to `nixosModules.tenant` (mirroring the
`<tenant>.vm` render, [ADR 0021 §2](0021-tenant-tls-vault-agent-and-secret-zero.md)):
`{{ with secret "pki_int/issue/temporal-client" "common_name=<cn>" }}` → cert + key + issuing CA
to **`/run/tenant/temporal/{tls.crt,tls.key,ca.crt}`**, renewed inside the 7-day TTL by
`krg.vaultAgent.renewal` ([ADR 0021 §2b](0021-tenant-tls-vault-agent-and-secret-zero.md)) — *this
sentence originally asserted auto-renewal that was never built; see the amendment below*. The
worker dials `krg-prod.ucsd.edu:7233`, presents that cert, verifies the server against `ca.crt`
with **TLS server-name `workflows.krg.ucsd.edu`**, and targets its namespace.

**CN:** the role currently allows the shared `temporal-worker`. For a per-tenant identity (useful
once §3's isolation lands) add `<tenant>-worker` to `var.temporal_client_domains` (or flip the role
to `allow_subdomains`). Start with a per-tenant CN — cheap, and future-proofs the authorizer.

### 3. Isolation posture — shared role now, per-namespace authorizer later

Granting a tenant `pki_int/issue/temporal-client` on the **shared** role means it can mint any
allowed CN, and — because **OSS Temporal does not enforce per-namespace authorization** (mTLS
authenticates the *connection*, not the namespace) — any valid client cert can target any
namespace. This is the **same shared-role posture the platform already accepts for
`tenant-internal`** (a granted tenant could mint another `<name>.vm`), so it is consistent, not a
new weakness. **Accept it for now** (few, semi-trusted tenants). Real per-namespace isolation =
a **Temporal authorizer** mapping cert CN → allowed namespace (plus per-tenant PKI roles) —
tracked in **#434**, worth doing before a second mutually-distrusting tenant shares Temporal.

### 4. Off-prem NRP worker — krg-deploy mints + delivers a k8s Secret

The NRP worker is off our OpenBao, so it can't self-render. **krg-deploy** mints a `temporal-client`
cert and delivers it as an **NRP k8s Secret** the worker mounts:

- **Automated (end state):** a krg-deploy timer/CD step mints the cert and `kubectl apply`s the
  Secret to NRP, refreshing inside the 7-day TTL. Needs an **NRP kubeconfig** brokered to krg-deploy
  (a new cred in OpenBao) — the one new dependency.
- **Interim (unblock now):** an admin mints a 30-day cert (`max_ttl`) and hands the team the PEM
  trio to load as a Secret manually; renew every 30d.

### 5. Phasing

1. `mkTenant.temporal` field + the `temporal-client` grant on the fishsense tenant policy
   (`terraform/openbao`) + a per-tenant CN in `var.temporal_client_domains`.
2. The in-slot vault-agent render in `nixosModules.tenant` (§2) — unblocks the in-slot workers;
   independently testable (mint on-box, like the broker test).
3. NRP delivery: the interim manual PEM now (§4); the automated krg-deploy→NRP-Secret step as a
   follow-up once an NRP kubeconfig is brokered.
4. (Later) per-namespace Temporal authorizer (§3).

## Consequences

- **Unblocks fishsense's workers** — both in-slot and NRP get a Temporal client cert, closing the
  HANDOFF §6 gap.
- **Consistent with ADR 0021** — the in-slot path is the same vault-agent render pattern, one more
  cert; the request/grant split is unchanged.
- **Security:** shared-role issuance is accepted (matches `tenant-internal`); real namespace
  isolation is explicitly deferred to a Temporal authorizer, and the non-enforcement is documented
  so no one assumes the namespace is a boundary.
- **New dependency (automated NRP only):** an NRP kubeconfig on krg-deploy. The interim manual path
  avoids it.
- **TTL/renewal:** 7-day issued / 30-day max. The in-slot agent re-renders on its schedule; the NRP
  Secret is refreshed by the timer (or manually at 30d).

**Amendment (2026-08-17) — "re-renders on its schedule" was false when written.** The in-slot
agent had no schedule: `krg.vaultAgent` is a `RemainAfterExit` oneshot with
`exit_after_auth = true`, so the leaf was rendered once at provision and expired exactly 7 days
later, taking the fishsense workflow pipeline down (`received fatal alert: CertificateExpired`,
~2,400 failed task-queue polls). Fleet hosts were masked from this by `deploy/deploy-nixos.sh`
restarting the agent each switch; tenants converge from their own flake and never run it. Two
things were missing and are now built (see [ADR 0021 §2b](0021-tenant-tls-vault-agent-and-secret-zero.md)):
`krg.vaultAgent.renewal` re-renders a leaf inside the last third of its lifetime, and the render
carries a `reloadCommand` so the worker — which builds its TLS config once at `Client.connect` —
actually picks the new cert up. **Keeping the 7-day TTL is deliberate** (`pki.tf`: *short — callers
re-issue*); with renewal real, a short TTL costs nothing and limits exposure of a leaked leaf.
The isolation posture in §3 is unchanged.
- Supersedes the "not yet wired" Temporal note in `docs/handoff/fishsense-lite/HANDOFF.md` §6 and
  the deferred-provisioning note in `terraform/temporal/README.md`.
