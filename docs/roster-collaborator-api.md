# Roster collaborator invitation API

The roster's `/collab-manage` page creates single-use, email-bound invitations
through the existing tenant/org enrollment flow. Its separate `collab-admins`
role is granted only through roster system administration. The infrastructure
support lives in
[`roster_collaborators.tf`](../terraform/authentik/roster_collaborators.tf).

## What changes in Authentik

- The existing brand publishes `attributes.roster_collaborators`: approved
  tenant/org pairs, the enrollment flow UUID/slug, and direct application links.
  It contains no credentials or reusable invitation tokens.
- A new Authentik-local service account, `svc-roster-invitations`, receives the
  **Roster collaborator invitation API** RBAC role.
- An `intent = "api"` token for that account is written to OpenBao at
  `secret/krg-prod/authentik-managed/roster-invitations` together with the
  Authentik URL and brand UUID.

The catalog derives FishSense partners from `local.collaborator_invites` and
includes Australian Museum under `frog-id`. These are partner registrations,
not invitations: they remain selectable independently of reusable invite expiry.
Application access still comes from `collaborator_tenants.tf`; adding a catalog
entry alone is not an application authorization grant.

## Why the existing credentials are insufficient

Roster's OIDC client secret supports interactive login; its current scope is
`openid profile email groups`. Its Samba bind password authorizes AD operations.
Neither is configured as an Authentik management API credential for the roster.
The deployment process already has an Authentik administrator API token at
`secret/krg-deploy/authentik-admin-token`, but that broadly privileged token must
remain with the deployer rather than be distributed to the web application.

This finding is based on checked-in wiring, not a live OpenBao/token inventory.
The new API token is a backend service identity, not a replacement OIDC secret,
not an app-password token, and not a personal credential for collab admins.

The backend needs two API operations:

| Operation | Purpose |
|---|---|
| `GET /api/v3/core/brands/<brand-id>/` | Fetch the tenant/org catalog and application links |
| `POST /api/v3/stages/invitation/invitations/` | Create an invitation and receive its UUID |

It sends `Authorization: Bearer <token>`. The token's service-account role has:

| Permission | Scope |
|---|---|
| `authentik_stages_invitation.add_invitation` | Global model permission |
| `view_brand` on `authentik_brands.brand` | The catalog brand only |
| `view_flow` on `authentik_flows.flow` | The collaborator enrollment flow only |

No superuser status, AD membership, group/user modification, or permission to
list existing invitations is granted. The add-invitation permission itself does
not constrain fixed data, lifetime, or single use: those restrictions are
enforced by the roster backend. Protect the service token accordingly.

## Merge and automatic deployment order

Merge [roster PR #88](https://github.com/UCSD-E4E/E4E-Roster-V3/pull/88) before
this infrastructure PR. The next normal fleet deploy performs the complete
rollout; no manual token creation, template edit, or credential copy is needed.

1. **Phase 1.5:** apply the early secrets workspace, then create the invitation
   secret path with `bao kv put -cas=0` only if absent. This placeholder contains
   no token. Existing values are never overwritten, including concurrent writes.
   Missing credentials or a failed bootstrap stops deployment before NixOS.
2. **Phase 2:** the shared agent renders the existing required roster secrets
   normally. A separate root-only `/run/krg/roster/invitations.env` contains blank
   API settings until Authentik supplies all three values. Compose loads it in
   raw mode after the existing backend environment file. Only invitations are
   temporarily unavailable; required roster secrets remain fail-closed.
3. **Phase 3:** the required Authentik target creates the catalog, service
   identity, role assignments, token, and OpenBao write-back. A skipped target or
   failed assignment fails the deploy; no superuser fallback is used.
4. **Phase 3.5:** require a successful agent rerender on krg-prod. The generated
   API URL, brand UUID, and token now populate the separate environment file.
   Its reload hook recreates affected Compose services instead of merely
   restarting a container with its old environment. The roster stack uses
   `failClosedOn`, so restarting the shared agent does not take down its database.
5. **Activate the roster:** require a clean `main` checkout at
   `/var/lib/krg/e4e-roster`; fetch the public roster main, reject local commits,
   fast-forward, build the backend, and reload the stack. A missing collaborator
   implementation, dirty checkout, wrong branch, or divergence fails explicitly;
   the deploy never resets or stashes local work.
6. **Verify:** compare the running backend's three API environment values with
   the rendered file internally, then check that the new route returns 403 to
   an anonymous caller and that the backend token can fetch the Authentik
   catalog. No token, Docker environment dump, or provider response is logged.
   A failure stops the deploy rather than deferring activation to another run.

After deployment, a roster system administrator must explicitly grant themselves
`collab-admins` at `/system/v2/collab-admins`. Then check `/collab-manage` and
create the first intended invitation. The deploy's API check is read-only; it
never creates production test invitations. Check single use, email binding, and
application access on that first intended enrollment.

The CAS bootstrap is orchestration, not a second Terraform owner: the Authentik
workspace alone manages the final secret. During a plan-only OpenTofu run the
bootstrap does not execute. A soft-deleted or unreadable path is an error rather
than permission to replace an existing token.

Historical RBAC assignment failures are recorded in
[`proxmox_ldap.tf`](../terraform/authentik/proxmox_ldap.tf). Provider validation
alone cannot prove live assignment works. Phase 3 and the catalog check surface
failures without granting the service account superuser access.

## Rotation and revocation

The token follows the existing infrastructure pattern and is non-expiring.
Rotate by replacing `authentik_token.roster_invitations` through OpenTofu, then
run the normal deploy, which rerenders the updated OpenBao value, recreates the backend, and checks that its running token matches. Verify
using API behavior rather than printing the key. Revoking the token stops API
use but does not revoke invitations or external users already created; handle
those separately in Authentik. Revoking a roster collab-admin grant also does
not revoke that person's issued invitations.

The full roster workflow and configuration are documented in
[collaborator-management.md](https://github.com/UCSD-E4E/E4E-Roster-V3/blob/main/docs/collaborator-management.md)
(available once the companion roster PR is merged).
