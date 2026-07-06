# 0022. Tenant self-hosted runners via a GitHub App token broker (and krg-deploy's own token)

**Status:** Proposed · **Date:** 2026-07-06

## Context

[ADR 0017](0017-incus-nat-self-serve-platform.md) §8 settled **repo-owns-deploy**: a tenant's
own repo drives changes into its Incus instance. [ADR 0020](0020-tenant-deploy-contract-mktenant.md)
gave the tenant a way to *declare* its deploy target (`lib.mkTenant`), and
[ADR 0021](0021-tenant-tls-vault-agent-and-secret-zero.md) closed the in-instance TLS seam. The
last seam — **"seam B"** in the fishsense hand-off — is the mechanism that makes repo-owns-deploy
actually *run*: a **self-hosted GitHub Actions runner on the tenant instance**, scoped to the
tenant repo, so a merged `auto-deploy/*` PR converges the instance.

Two gaps block it:

1. **No runner on tenant instances.** `nixosModules.tenant` deliberately does not wire one yet.
2. **No sane registration credential.** krg-deploy's *own* runner
   (`services.github-runners.krg-deploy`, `nix/hosts/krg-deploy/default.nix`) registers from a
   hand-placed `github-runner-token` — a short-lived registration token or a broad PAT — flagged
   as bring-up debt to move to a lab-owned identity in OpenBao (issue #121). A per-tenant runner
   multiplies that debt: we are NOT hand-placing a token per tenant, and a tenant must not hold a
   credential that can register runners on arbitrary repos.

The right primitive is a **GitHub App** (org-scoped, short-lived installation tokens minted from
a private key) rather than a PAT. fishsense forces it, and the same App retires #121.

A registration token is short-lived (~1h) and single-purpose: a runner uses it **once** to
register, then stores its own long-lived credentials. So the problem is not "keep a token live"
but "broker a fresh registration token to each runner at (re)registration, from a credential the
tenant never holds."

## Decision

### 1. One GitHub App per org; its key is the broker's secret-zero (in OpenBao)

Create a GitHub App in each org that hosts a runner target — `KastnerRG` (krg-deploy) and
`UCSD-E4E` (tenants) — with **`administration: write`** (self-hosted runner registration),
installed on the relevant repos. Its `app-id` + `installation-id` + **private key** live in
OpenBao (`secret/krg-deploy/github-app/<org>`), read by krg-deploy's existing AppRole. Creating
the App + installing it is a one-time **org-admin action** — the bring-up gate for everything
below. (No App = nothing downstream can register.)

### 2. A token broker on krg-deploy

A small helper (`deploy/mint-runner-token.sh`, invoked by the broker steps below) mints, per
target repo: App JWT (signed with the key, ≤10 min) → installation token (1h) → **runner
registration token** via `POST /repos/{owner}/{repo}/actions/runners/registration-token`. Two
consumers:

- **krg-deploy's own runner (closes #121):** a systemd timer renders the registration token to
  `tokenFile`, replacing the hand-placed secret. The App key never leaves krg-deploy.
- **Tenant instances:** the token is pushed into the instance by **`incus file push` at
  provision — mirroring [ADR 0021 §3](0021-tenant-tls-vault-agent-and-secret-zero.md)'s
  secret-zero delivery** (CD Phase 3.x). It is a bootstrap credential exactly like secret-zero,
  so it reuses that transport and its fail-closed posture. A fresh token each deploy is ample: a
  **persistent** runner (below) registers once and a between-deploys expiry is harmless.

### 3. The runner on the instance is persistent, in `nixosModules.tenant`

`services.github-runners.<tenant>` mirrors krg-deploy's block: `url` = the tenant repo (from the
mkTenant `repo` field), `tokenFile` = the brokered path, `replace = true`, `workDir` =
`DEPLOY_DIR`, and docker + `nixos-rebuild` + git on PATH. **Persistent, not ephemeral:** the
single-tenant VM *is* the isolation boundary (ADR 0017 §4), so re-registering per job buys little
and would force continuous token re-brokering. The runner runs as a dedicated user with a
narrowly-scoped ability to run the one `nixos-rebuild`/compose switch (the polkit-scoped pattern
krg-deploy already uses for its self-update), NOT broad sudo.

### 4. Bootstrap: krg-deploy applies the tenant flake ONCE; the runner self-sustains after

The instance boots **golden** (no runner). krg-deploy performs the **first convergence** at
provision — `incus exec <name> -- nixos-rebuild switch --flake <repo>#<name>` (the instance has
egress NAT to fetch the flake; no ssh-into-the-NAT needed) — which installs the runner. From then
on the tenant's `auto-deploy/*` workflow runs **on that runner**, doing `nixos-rebuild switch
--flake .#<name>` **locally** for config changes and `docker compose up` for interior changes.
krg-deploy bootstraps; the tenant sustains. (Rejected: a golden first-boot self-bootstrap from a
repo ref in incus config — more golden machinery for a once-per-instance action krg-deploy can do
with its existing incus access.)

To make the first `nixos-rebuild` evaluable without a per-instance capture, tenant flakes import a
**shared golden hardware profile from krg-infra** (all golden instances have identical virtio
hardware) rather than a hand-captured `hardware-configuration.nix` — a hand-off simplification
this ADR introduces.

## Consequences

- **fishsense reaches end-to-end.** With the App created (§1) and the broker + runner + bootstrap
  (§2–§4) landed, a merged `auto-deploy/*` PR brings up fishsense's inner Traefik (serving the
  `fishsense.vm` cert from ADR 0021) and app stack; the already-live edge re-encrypt then
  completes `https://fishsense.e4e.ucsd.edu`. This is the final platform-owned gate.
- **#121 is retired** in the same change: krg-deploy's runner moves off its hand-placed token to
  the App broker.
- **Security.** The runner executes tenant-controlled workflow code AND holds root-ish rebuild
  rights — but only on *its own* single-tenant instance, which the tenant already owns. Lateral
  blast radius is bounded by the Incus NAT (egress-only, no cross-instance path) and the
  per-tenant OpenBao AppRole (ADR 0021). The App key stays on krg-deploy; the tenant only ever
  holds a short-lived, repo-scoped registration token — never a minting capability.
- **Phasing.** (0) create the App (org-admin, gate). (1) broker + move krg-deploy's own token to
  it (closes #121, independently testable). (2) `services.github-runners.<tenant>` in
  `nixosModules.tenant` + the shared golden hardware profile. (3) provision-time token push
  (Phase 3.x, mirrors PR 2) + the first-convergence bootstrap. (4) the tenant repo's
  `auto-deploy/*` workflow (tenant-side, folded into the hand-off).
- **New coupling.** krg-deploy gains a per-tenant provision step (token push + first switch),
  idempotent and fail-closed like the secret-zero leg. A tenant whose App install or instance
  isn't ready is skipped with a warning, never a fleet failure.
- Supersedes the "an admin brings the stack up manually" interim in
  `docs/handoff/fishsense-lite/HANDOFF.md` §3 seam B, and the hand-placed-token note in
  `nix/hosts/krg-deploy/default.nix` (#121).
