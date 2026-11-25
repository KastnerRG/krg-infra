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

## Apply and activate in stages

1. Review and apply the Authentik workspace through the normal deployment.
   The current PR does not add an unseeded secret reference to the shared runtime
   renderer, so deploying the resources first cannot break unrelated renderers.
2. Verify that the dedicated account can read the configured brand and create a
   disposable test invitation for an approved tenant/org. Confirm single use,
   email binding, and the expected flow. An Authentik operator should remove an
   unused test invite: the service account has no list/delete permission.
3. After successful verification and OpenBao write-back, add the following block
   to the existing `/run/krg/roster/backend.env` template in
   [`nix/hosts/krg-prod/default.nix`](../nix/hosts/krg-prod/default.nix) as a
   separate staged infrastructure change:

   ```text
   {{ with secret "secret/data/krg-prod/authentik-managed/roster-invitations" }}
   AUTHENTIK_URL={{ .Data.data.url }}
   AUTHENTIK_BRAND_ID={{ .Data.data.brand_id }}
   AUTHENTIK_API_TOKEN={{ .Data.data.token }}
   {{ end }}
   ```

4. Rerender through the existing agent and recreate/restart the roster backend
   through the normal deployment. Keep the root-only environment file and raw
   Compose env-file handling; do not put the token in the checkout `.env`.
5. Have a roster system administrator explicitly grant themselves `collab-admins`
   at `/system/v2/collab-admins`, then check `/collab-manage` end to end. Without
   the grant, even a system administrator must receive 403.

The shared OpenBao renderer fails closed on missing fields. Do not combine
runtime activation with an unverified/unseeded token path. Until configuration
is supplied, the new roster page reports it is unavailable; other roster
features remain usable.

Historical RBAC assignment failures are recorded in
[`proxmox_ldap.tf`](../terraform/authentik/proxmox_ldap.tf). Provider schema
validation does not prove those endpoints work on the deployed Authentik
version. If assignment fails, diagnose that failure rather than granting the
service account superuser access.

## Rotation and revocation

The token follows the existing infrastructure pattern and is non-expiring.
Rotate by replacing `authentik_token.roster_invitations` through OpenTofu, then
rerender the updated OpenBao value and recreate/restart the backend. Verify
using API behavior rather than printing the key. Revoking the token stops API
use but does not revoke invitations or external users already created; handle
those separately in Authentik. Revoking a roster collab-admin grant also does
not revoke that person's issued invitations.

The full roster workflow and configuration are documented in
[collaborator-management.md](https://github.com/UCSD-E4E/E4E-Roster-V3/blob/main/docs/collaborator-management.md)
(available once the companion roster PR is merged).
