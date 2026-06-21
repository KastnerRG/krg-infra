# 0013. SSO via Authentik is the front door; AD is the identity source

**Status:** Accepted · **Date:** 2026-06-20

## Context

ADR 0009 and ADR 0010 establish KRG.LOCAL (the Samba AD forest on `krg-ldap`) as
"the lab's single identity authority" — host logins, Grafana/Authentik SSO,
`/scratch` ownership, GPU/Docker access all key off AD groups. But both ADRs only
**assert** that AD is the authority. Neither imposes an *obligation* on a new
service to use it, and neither says how someone who needs only a web login — an
outside collaborator — gets access. Those two gaps are this ADR.

The assertion is not self-enforcing. A new service — Fleet, the lab-owned MDM
control plane stood up under ADR 0012 ([[mdm-is-campus-intune-not-fleet]]) — was
evaluated in a parallel effort and **defaulted to a standalone local user store**,
wiring SSO only after it was pushed — despite the same CLAUDE.md and the same
0009/0010 in context. Fleet supports SAML/OIDC; nothing written down said it *had*
to federate, so the default path didn't. That is the same drift-by-omission failure
mode ADR 0001 exists for: if the rule isn't stated, the absence of the rule is what
gets built. This ADR is the federation rule ADR 0012's services should have had to
point at.

The second gap is over-granting. 0010 frames "every human" as an AD account owned
by roster. But a collaborator who needs only `docs.krg` or a Grafana dashboard
does **not** need to become a domain principal — an AD account carries host login,
Kerberos, storage and compute reach. Issuing full AD identity to satisfy a
web-only need is least-privilege backwards: it hands broad trust to satisfy a
narrow one.

## Decision

### 1. AD is the source; Authentik is the interface

AD holds the authoritative users and groups. **Authentik is the single front door**
— it speaks the many authentication languages services actually want (OIDC, SAML,
LDAP-outpost) and brokers them back to one AD-backed identity. The mental model:
**AD is the source of truth, Authentik is the multilingual interface to it.**

### 2. Federation order — Authentik first, direct-AD second

A service authenticates through **Authentik** wherever it can. Binding **directly**
to AD (Kerberos/LDAP/SSSD against the DC) is the *fallback*, used only when a
service genuinely can't go through Authentik. "Through Authentik" is broader than
OIDC — Authentik also fronts AD over **LDAP via its LDAP outpost**, so even a
client that can't do the browser redirect still routes through the front door:

- **Authentik — OIDC/SAML (preferred):** web apps that speak the browser flow —
  Grafana, Outline, MLflow, Label Studio, Vaultwarden, Fleet's admin console, etc.
  One login, one MFA surface, one place to revoke.
- **Authentik — LDAP outpost:** clients that can only do a plain LDAP bind, *still
  through Authentik, not raw AD*. **Proxmox VE** is the case
  ([[proxmox-uses-ad-realm-not-oidc]], `docs/proxmox-auth.md`): its PVE LDAP realm
  binds the Authentik **LDAP outpost** (`terraform/authentik/proxmox_ldap.tf`),
  because the PVE apps can't do OIDC's redirect *and* because the outpost flattens
  nested AD groups PVE can't expand itself. The outpost is Authentik serving AD over
  LDAP — front door, not fallback.
- **Direct AD (true fallback only):** protocol-level identity with no Authentik
  path at all — host SSSD logins (`krg.adClient`), NFS/SMB, Samba/Kerberos. These
  bind the DC directly because the protocol can't be brokered, not by preference.

Favoring Authentik — OIDC where possible, the LDAP outpost where not — gives a
single entry point into everything and keeps the per-service blast radius small;
direct-to-DC bindings are minimized, not multiplied.

### 3. New-service obligation (the gate)

**Any new service that supports SAML, OIDC, or LDAP MUST federate to lab identity
rather than ship a standalone user store.** Per decision 2 that means Authentik
first, direct-AD only where Authentik can't reach. A local/native account store is
permitted **only** for:

1. **Break-glass admins** (the per-host `krg-admin`/`e4e-admin`, the `akadmin`
   bootstrap) — deliberate recovery identities, off the federation path by design.
2. **Services with no federation support** — recorded as an **explicit exception**
   (in the service's deploy notes or an ADR), never as a silent default.

This is the testable rule the next service — and the next agent — gets measured
against, the way ADR 0001's "git is truth" gets invoked reflexively. "It shipped
with local accounts because nothing said otherwise" is no longer a valid outcome.

### 4. Two trust tiers — members in AD, collaborators in Authentik only

- **Lab members → AD.** Full-trust principals: host login, storage, compute, and
  web SSO, all keyed off AD groups. Owned per 0010 (humans = roster's; structure =
  IaC).
- **External collaborators → Authentik-local, minimal trust.** Someone who needs
  only web services is the **exception** and does **not** get an AD account. They
  get an Authentik-local account, authorized **explicitly per application**, with
  **no** AD group membership and therefore no host/compute/storage reach. Minimal
  trust by construction: the account can reach exactly the app(s) it was granted
  and nothing else. Onboarding is an **Authentik invitation flow** (an admin sends
  a scoped invite; the collaborator self-enrolls into a local account) — not AD
  provisioning, and not an open self-signup. That flow is **not yet built** (see
  follow-ups); until it exists, there is no collaborator-onboarding path, which is
  the safe default.

This refines 0010: "every human is an AD account" holds for **members**; web-only
collaborators are the deliberately-scoped exception that minimal-trust justifies.

### 5. Authorization still keys off AD groups (for AD users)

Decision 4 does not loosen [[authentik-groups-from-ad]]: authorization for
**AD-sourced users** is still driven by **AD group names** synced into Authentik,
never by local `authentik_group` resources. Collaborator authorization is by
**direct per-application assignment** (minimal trust). If a collaborator ever needs
grouping, that local construct is the documented exception to
[[authentik-groups-from-ad]], scoped to external-only apps — not a general escape
hatch.

## Consequences

- The next service evaluation has an explicit gate to fail against: no federation
  path chosen = an exception that must be written down, not a default. The Fleet
  near-miss becomes a caught case rather than a missed one.
- Direct-AD bindings stay a short, justified list (host login, Proxmox realm,
  NFS/SMB) instead of growing one-per-service. Revocation and MFA concentrate at
  Authentik.
- Collaborators no longer require AD provisioning. A wiki-only guest is an Authentik
  account, created and revoked without touching the directory or granting host
  reach — least privilege for the actual need.
- This ADR is policy, not code: it imposes obligations on `terraform/authentik/`
  and on new-service deploys, consistent with 0009/0010. It adds no new module.

## Alternatives considered

- **Leave it implicit in 0009/0010.** Rejected — that's exactly what produced the
  Fleet near-miss. The decision needs title-level visibility so an agent scanning
  ADR titles for "SSO" finds the obligation; that discoverability is the whole point
  (ordering is just the next free id — ADR numbers are identifiers, not ranking).
- **Fold it into 0010 as a paragraph.** Lighter, but lower discoverability and it
  bloats the AD-structure ADR with a cross-cutting service policy. A standalone
  record that cross-links 0009/0010 keeps each ADR single-purpose.
- **Give collaborators scoped AD accounts.** Rejected — even a low-privilege AD
  account is a domain principal (Kerberos, host login surface). An Authentik-local
  account grants strictly web reach and nothing in the directory.
- **Let services bind AD directly when convenient.** Rejected — multiplies
  direct-AD integrations, fragments MFA/revocation, and defeats the single-front-
  door value. Direct AD is a fallback, not a peer option.

## Out of scope / follow-ups

- **Authentik invitation flow for collaborators.** Decision 4 sets the policy; the
  mechanism — an Authentik **invitation/enrollment flow** that mints a minimal-trust
  local account from an admin-issued, app-scoped invite (no AD write, no open
  self-signup) — still needs building in `terraform/authentik/`, along with where a
  collaborator's per-app authorization is declared. Owned by the SSO effort
  ([[terraform-openbao-authentik-hands-off]]). No collaborator can be onboarded
  until it lands.
- **Authentik password-strength/breach policy** — **now landed**
  (`terraform/authentik/password_policy.tf`: length ≥12 + HIBP breach + zxcvbn,
  bound to the recovery and change-password flows), closing ADR 0010 §4. It is the
  enforcement that bounds the minimal-trust collaborator accounts of decision 4
  (local, non-AD → no AD write-back, so this policy is their *only* strength gate).
- **Exception register.** Where "no-federation" exceptions (decision 3) are
  recorded — per-service deploy notes vs. a running list — to be decided as the
  first such exception appears.
