# terraform/authentik — Authentik SSO config

Manage **Authentik's objects** declaratively with the `goauthentik/authentik`
provider, instead of click-ops in the Authentik admin UI.

> Built out: applications + their OAuth2/OIDC and proxy providers
> (`applications_krg.tf`, `applications_e4e.tf`), the Samba AD LDAP source +
> superuser mapping (`ldap.tf`, `groups.tf`), the proxy outpost (`outpost.tf`),
> and the OpenBao secret writeback (`vault_secrets.tf`, `roster_secrets.tf`).
> State, secrets, and apply discipline below still apply.

**Scope: config, not deployment.** Authentik runs as a Docker Compose stack on
**krg-prod** (`nix/docker-compose/krg-prod/compose.authentik.yml`). That stays.
This target manages what lives *inside* Authentik:

- Applications + their OAuth2/OIDC and proxy providers
  (`applications_krg.tf`, `applications_e4e.tf`)
- The Samba AD LDAP **source** (`ldap.tf`) — federates `KRG.LOCAL`; default
  flows/cert are read-only `data` lookups (`data.tf`), not managed here
- Group property mappings: AD `Domain Admins` → Authentik `is_superuser`
  (`groups.tf`). Groups are **AD-sourced** via the LDAP source, not local
  `authentik_group` resources
- A proxy **outpost** (`outpost.tf`) and the generated-OIDC-secret writeback
  into OpenBao (`vault_secrets.tf`, `roster_secrets.tf`)
- Custom **flows**: self-service password recovery (`recovery.tf`),
  passwordless **passkey** login (`passkey.tf`), and the external-collaborator
  **invitation / enrollment** flow (`collaborator_enrollment.tf`,
  `fishsense_collaborators.tf`) — see below. Recovery + passkey are wired into
  the live login screen via `brand.tf` (the one fleet-wide stage it manages).
- **SSO session lifetime** (`session.tf`): 12h base session + a "Remember me"
  checkbox extending opted-in sessions to ~30 days. This is the real "stay logged
  in" knob (the `session_duration` on the default login flow's `user_login`
  stage) — distinct from the per-app `refresh_token_validity` in
  `applications_*.tf`. Requires a one-time `tofu import`, documented in the file.

## Passkey (passwordless WebAuthn) login — `passkey.tf`

Users register a passkey (platform biometric or a security key / phone) from
**Account → Settings**, then sign in with just the passkey — no KRG.LOCAL
password. The password path stays; the passkey adds a **"Use a passkey"** button
to the same login screen.

`passkey.tf` builds, the `recovery.tf` way, a self-contained passwordless flow
(`authentik_flow.passwordless` → a webauthn `authenticator_validate` stage →
`user_login`) plus an enrollment stage bound into the user-settings flow. The
enrollment stage forces **discoverable (resident)** credentials so they work in
the passwordless flow.

The button itself is the `passwordless_flow` attribute of the
`default-authentication-identification` stage — the stage *every* login screen
runs. That stage is **already managed in `brand.tf`** (imported there to wire the
recovery link), so the button is turned on by **one line in `brand.tf`**, not by
importing the stage again here. No extra import step beyond the one `brand.tf`
already documents.

> `user_verification` is left at `"preferred"` (won't lock out authenticators
> that can't do UV). For stricter passwordless, flip it + `webauthn_user_verification`
> to `"required"` in `passkey.tf`.

## Collaborator invitations (external partners) — `collaborator_enrollment.tf`

The onboarding path for an **external collaborator** — someone who needs only web
services and is **not** a lab member (ADR 0013 §4). They get an Authentik-**local**
account (no AD account → no host/compute/storage reach), authorized explicitly per
application. `collaborator_enrollment.tf` builds, the `recovery.tf` way, a
self-contained **enrollment** flow:

    invitation → prompt (email/name/username/password) → user_write (external,
    inactive) → email (verify + activate) → user_login

- **Invite-only.** The invitation stage sets `continue_flow_without_invitation =
  false`, so the flow dead-ends without a valid invite token — **no open
  self-signup** (the §4 requirement). Do not flip that switch.
- **Email-verified.** The account is created **inactive** and only flipped active
  when the invitee clicks the confirmation link (`activate_user_on_success`).
- **UCSD password gate.** The prompt reuses `authentik_policy_password.ucsd` —
  for a non-AD account this is the *only* strength/breach gate (no AD write-back).
- Invitees are `user_type = "external"` — the marker that keeps them out of the
  member/AD trust tier.

### Minting an invite

There is **no `authentik_invitation` provider resource** — invites are
per-collaborator and ephemeral, and would leak their pre-fill data into tofu
state. An admin mints each one out of band:

**Directory → Invitations → Create**, selecting flow `krg-collaborator-enrollment`,
`Single use = on`, an expiry, and (for a tenant collaborator) **Custom attributes**:

```json
{ "attributes.tenant": "fishsense", "attributes.org": "<org-id>" }
```

Send the invitee the enrollment URL with the token:
`https://auth.krg.ucsd.edu/if/flow/krg-collaborator-enrollment/?itoken=<token>`.
The `attributes.*` keys must match the hidden prompt fields' `field_key`s — that
prefix is what makes `user_write` persist them onto `user.attributes`. A generic
(non-tenant) collaborator just omits the custom attributes.

### FishSense multitenancy — `fishsense_collaborators.tf`

FishSense is multitenant: many external partner orgs, isolated **inside
FishSense's own DB keyed on the stable OIDC `sub`** (its providers use
`sub_mode = "hashed_user_id"`). Authentik only authenticates the partner and tells
FishSense which org they are:

- The invite's `attributes.org` / `attributes.tenant` land on the user.
- The `org` OIDC scope mapping emits them as claims (FishSense must **request the
  `org` scope** — same request-to-receive contract as the `groups` scope).
- Access to the FishSense apps is an **expression policy** (`tenant ==
  "fishsense"`) bound alongside the existing `FishSense` AD-group gate. Because
  the apps' `policy_engine_mode` is `any` (OR), access = FishSense **members** OR
  FishSense **collaborators**.

This is deliberately **attribute/claim-driven, not per-org Authentik groups** —
it scales to arbitrarily many partner orgs with no per-org object in this repo,
and FishSense is authoritative on the sub→org mapping regardless. Per-org isolation
is FishSense's job; Authentik is the IdP.

## Prerequisites before this can plan

1. Authentik reachable (its URL on krg-prod).
2. An **API token** — the bootstrap `akadmin` token or a dedicated
   service-account token (stored in OpenBao at
   `secret/krg-deploy/authentik-admin-token`).
3. A reachable **OpenBao** server — this workspace writes the generated OIDC
   client secrets back into it for downstream workspaces (`grafana/`) to read.

Three providers are configured (`providers.tf`): `authentik` (the objects),
`vault` (OpenBao secret writeback), and `random` (`roster_secrets.tf`). Apply
needs these env vars:

```bash
export TF_VAR_authentik_token="<authentik API token>"
export TF_VAR_ldap_bind_password="<authentik-bind password>"
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<vault token>"
tofu init && tofu apply
```

## Notes

- Tokens (and any created provider client secrets) land in **state** → this is
  exactly why state encryption / a backend matters before going live (see
  [`../README.md`](../README.md#secrets--state-shared-rules)).
- Natural SSO loop: Authentik becomes the **OIDC provider for OpenBao** auth
  (`../openbao/`), and can front AD identity from `KRG.LOCAL`.
