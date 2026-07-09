# 0014. Proxmox VE authenticates via the Authentik LDAP outpost — not OIDC, not raw AD

**Status:** Accepted · **Date:** 2026-06-21

> **Narrowed by [ADR 0017](0017-incus-nat-self-serve-platform.md) (2026-06-25).** This
> decision is now **Proxmox-specific**: the LDAP-outpost binding covers PVE only. The new
> Incus control plane authenticates via **OIDC→Authentik directly** (the OIDC realm PVE
> couldn't use — its mobile app can't redirect — is fine for Incus). Revisit if/when PVE
> is retired.

## Context

Proxmox VE is the hypervisor control plane; lab admins log into its web UI **and
its mobile/CLI apps**. Under ADR 0013 it must reach lab identity through Authentik
where it can, and key authorization off the AD group `proxmox-admins`. The question
this ADR settles is *how* PVE binds to that identity — and it settles it against two
approaches that were each **built and then removed**, so the record exists to stop a
third lap.

**Attempt 1 — Authentik OIDC realm (removed).** PVE supports an OpenID realm, so the
first design pointed it at an Authentik OAuth2/OIDC provider (the `pve_oidc` role +
an Authentik provider, the #294→#311 fix-chain). Two things killed it:

- **The Android app can't authenticate via OIDC.** Admins **reboot servers from the
  Proxmox Android app**, so Android support isn't a nice-to-have — it's an
  operational requirement, and OIDC's browser-redirect flow leaves the app dead.
  This alone is disqualifying.
- **Admin groups couldn't be configured** through the Authentik group-expression path
  (the 2026.5 expression breakage — [[authentik-2026-expression-gotchas]]), so
  `proxmox-admins → Administrator` wouldn't map cleanly.

The group-expression problem was *probably* solvable with more effort — but since the
Android app would stay broken regardless, solving it wasn't worth it. Android decided
it; the group issue made continuing pointless.

**Attempt 2 — native PVE Active Directory realm against krg-ldap (removed).** The
next design used PVE's built-in AD realm binding the DC directly (the `pve_ad` role).
It logged in, but **PVE does not expand nested groups** — it reads a group's direct
`member` attribute and ignores sub-groups. `Domain Admins` is nested inside
`proxmox-admins`, so PVE saw an *empty* admin group. The only raw-AD fix was to add
the admin users **directly** to `proxmox-admins` in the directory — which **clutters
AD** with a flattened, PVE-specific membership duplicating the nesting we model on
purpose. We didn't want to pollute the directory to work around a PVE limitation.
Binding raw AD also puts a second, parallel identity integration next to Authentik —
exactly the multiplication ADR 0013 decision 2 rejects.

## Decision

**PVE authenticates with an LDAP realm bound to the Authentik LDAP outpost** — a plain
LDAP bind, served by Authentik, backed by AD. This is "Authentik-first in the LDAP
dialect" (ADR 0013 decision 2): the front door, reached over LDAP because the apps
can't do OIDC.

It resolves both failures at once:

- **LDAP is a plain bind** — no browser redirect — so the web UI *and* the mobile/CLI
  apps all work.
- **Authentik's LDAP source flattens nested groups.** The outpost presents the six
  `Domain Admins` members as *direct* members of `proxmox-admins`, so PVE reads an
  already-flattened directory and the admin group is non-empty — **without writing the
  flattened membership back into AD** (the clutter that sank attempt 2). The
  flattening lives in the outpost, the directory stays clean. Drop someone from
  `Domain Admins` → Authentik re-syncs → they're gone from PVE. No flatten job.
- **It stays one identity plane.** PVE rides the same Authentik that fronts every
  other service; AD remains the source, Authentik the interface.

`proxmox-admins` (deliberately space-free — PVE group ids can't contain spaces) syncs
into PVE and is ACL'd **Administrator** on `/`. Local **PAM** (`root@pam`/`krg-admin`)
stays break-glass, off this path. Authentik also keeps a **provider-less link tile**
for Proxmox so the lab dashboard still lists it — the tile is *not* the auth path, the
outpost is.

The build is IaC end to end: `terraform/authentik/proxmox_ldap.tf` (provider, app,
outpost, `svc-pve-ldap` bind account, bind creds → OpenBao), `outpost_tokens.tf` (the
outpost token, minted in IaC → OpenBao), the `authentik_ldap` container in
`compose.authentik.yml` (LDAPS **6636**), and `ansible/roles/pve_ldap` (the PVE realm,
sync timer, group ACL). The phased-deploy bring-up, the three independent login layers
(outpost+token, the per-guest **6636** firewall opening, the app-access policy
binding), and the `ldapsearch` validation steps live in the runbook
**`docs/proxmox-auth.md`** — this ADR records the *why*, that doc the *how*.

## Consequences

- All three PVE client types (browser, mobile, CLI) authenticate against lab identity;
  no client is stranded the way OIDC stranded the apps.
- Group membership has one writer and no flatten job: AD nesting is resolved by the
  outpost, and `proxmox-admins` stays correct by re-sync.
- A new dependency in the login path — the `authentik_ldap` outpost — so PVE login now
  depends on krg-prod (the Authentik host), not only on krg-ldap. The local PAM
  break-glass is the continuity if the outpost is down.
- The OIDC and raw-AD roles/providers are removed; the superseded SSO/OIDC fix-chain
  (#294→#311) and the raw-AD-realm attempt should not be reintroduced.

## Alternatives considered

- **Authentik OIDC realm.** Built then removed — the **Android app** can't do the
  redirect flow and admins reboot servers from it, plus admin groups wouldn't map
  through the Authentik expression path (attempt 1). Can't be the front door for this
  service.
- **Native PVE AD realm (bind the DC directly).** Built then removed — PVE doesn't
  expand nested groups, so `proxmox-admins` came up empty, and the only fix clutters
  AD with flattened PVE-specific membership; also a second identity integration
  parallel to Authentik (attempt 2), against ADR 0013.
- **Raw AD + a custom group-flatten job.** Rejected — re-implements, as bespoke
  cron, exactly the flattening Authentik's LDAP source already does for free, and
  still writes the flattened membership into AD (the clutter we rejected above).
- **No SSO; local PVE users.** Rejected by ADR 0013's federation gate — PVE speaks
  LDAP, so it must federate.

## Out of scope / follow-ups

- **In-guest Docker-publish bypass for 6636.** Docker DNATs the published outpost port
  past the in-guest firewall, so `krg-prod:6636` is world-reachable regardless of the
  perimeter rule; access control today is the per-guest PVE firewall. Closing the
  bypass needs a `DOCKER-USER`/nftables FORWARD rule — the same open item as dcgm 9400
  (CLAUDE.md "Docker published-port firewall bypass").
- **Scoped search permission.** `svc-pve-ldap` is in the built-in `authentik Admins`
  group because the scoped `search_full_directory` permission can't be assigned via
  IaC on our version (goauthentik/authentik#18562); narrow it once that's fixed.
