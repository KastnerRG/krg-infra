# Outline group sync via Temporal

Implementation: `nix/docker-compose/outline-group-sync/`. Deployment module:
`nix/modules/services/outline-group-sync.nix`, imported by krg-prod but **disabled
by default**. No existing service, user, group, or collection changes until enabled.

## Behavior

- Reads the `krg-samba-ad` LDAP source's group-source connections in Authentik.
  Local Authentik groups are excluded. AD's nested memberships are already flattened
  by this source's `memberOf:1.2.840.113556.1.4.1941:` configuration.
- Creates a local Outline group with the same name for every LDAP-backed group,
  including empty groups. No allowlist or mapping file is required.
- Matches **existing Outline users** by case-insensitive email. Missing people are
  skipped, never invited or provisioned. On first normal SSO login, Outline creates
  the user; the next reconciliation adds their memberships.
- Only active, internal Authentik users can acquire memberships. Suspended Outline
  users and guests are excluded. This does not change the existing Authentik app gate.
- Adopts a same-name local Outline group, then makes its membership authoritative.
  **Manual membership additions to that group will be removed on the next sync.**
  Other local groups are untouched. Groups owned by another external source cause
  the whole plan to fail before writes.
- Records ownership in `externalId = krg-ldap:<source UUID>:<group UUID>`.
  LDAP renames update the same Outline group, preserving collection grants. Deleted
  LDAP groups are emptied but retained in Outline. A completely empty LDAP snapshot
  is rejected rather than interpreted as deleting all memberships.
- Never changes collection/document permissions, user roles, or account activation.
  For example, mirroring `Domain Admins` does **not** make its members Outline admins.
  Assign collection access to groups in Outline as usual.

All pages of users, groups, and group memberships are read before writes. Failed,
incomplete, or ambiguous reads abort the run. LDAP must be idle, its most recent
sync successful (`done`/`info`), and its last successful sync less than 24 hours old.
Status is checked again after reading. This catches LDAP syncs spanning the read;
the APIs do not provide a cross-service transaction, so concurrent manual changes
may still race a run and will converge on the next one.

Temporal runs one reconciliation every five minutes with overlap policy `SKIP`.
HTTP calls are Activities with timeouts, heartbeats, and retries. A retry rebuilds
the plan from current state, so partial writes, including a successful group create
followed by a rate limit, converge without duplicate groups. Initial creation of
many groups may take several retries because Outline limits `groups.create` to ten
requests per minute. Run one worker deployment and avoid simultaneous one-shot
`--apply` commands; the APIs do not enforce unique group external IDs.

## Validate locally

Python 3.11+ is required. From the repository root:

```bash
cd nix/docker-compose/outline-group-sync
uv sync --frozen
uv run --frozen pytest -q
uv run --frozen python sync.py
```

The one-shot command defaults to **dry run** and needs these environment variables
(load tokens securely into the environment; never commit token values):

```text
AUTHENTIK_URL=https://auth.krg.ucsd.edu/api/v3/
OUTLINE_URL=https://docs.krg.ucsd.edu/api/
AUTHENTIK_TOKEN=<read-only service-account API token>
OUTLINE_TOKEN=<Outline admin API token with the scopes below>
AUTHENTIK_LDAP_SOURCE=krg-samba-ad
LDAP_MAX_AGE_HOURS=24
```

Dry run prints the exact group/membership operations, including group names and
user UUIDs. Treat the output as internal. Only `python sync.py --apply` writes.
Neither mode requires a Temporal connection. Test fixtures use the versioned API
serializer shapes; a real authenticated dry run is still a required rollout gate.

## Credentials and deployment

Create dedicated credentials through the existing provisioning process:

- Authentik: read access to the configured LDAP source and its sync status, LDAP
  group-source connections, all relevant core groups, and core users (including
  email, type, active state, and group IDs). The account must see the **complete**
  directory; an RBAC-filtered API response can be internally consistent but partial.
  No Authentik write permissions are needed.
- Outline: an admin-owned API token scoped to `users.list`, `groups.list`,
  `groups.memberships`, `groups.create`, `groups.update`, `groups.add_user`, and
  `groups.remove_user`. No user invitations, user role changes, or collection writes.
- Store the tokens in OpenBao KV-v2 at
  `secret/krg-prod/authentik-managed/outline-group-sync`, fields `authentik_token`
  and `outline_token`. Provision these actual API-issued values; random strings
  generated in Terraform are not API credentials.

krg-prod's existing OpenBao policy can read `authentik-managed/*` and issue the
`temporal-worker` client identity. The module renders API credentials and a dedicated
Temporal client certificate to `/run/krg/outline-sync/`; tokens go only to the worker,
not the schedule registration container. The client certificate's renewal hook
restarts only this worker stack. The existing `default` Temporal namespace is used;
namespace separation in this cluster is by convention, not an authorization boundary.

After seeding credentials and reviewing a real one-shot dry run, enable scheduled
dry runs in `nix/hosts/krg-prod/default.nix` through the usual IaC deployment:

```nix
krg.outlineGroupSync = {
  enable = true;
  apply = false;
};
```

This starts a separate `outline-group-sync` compose project. Its image is built
from the committed source and hash-locked Python dependencies; a source change gets
a new image tag. A one-shot container registers the five-minute schedule, preserving
an existing schedule's configuration and paused state. The worker logs operation
counts; API tokens and full plans never enter Temporal workflow history.

Review the `outline-group-sync` schedule in Temporal and the worker logs. Confirm
one existing user's expected memberships, an account that has never logged in
(must remain absent), and the handling of existing same-name Outline groups.
Then change `apply = true` through IaC. Verify a second run reports zero changes,
and test a membership removal and a first SSO login with a test account.

Rollback: set `apply = false` to keep planning without writes, or disable the module
to stop the worker. Disabling leaves the Temporal schedule and existing Outline
groups intact; pause that schedule in Temporal if retiring the integration. Existing
schedule registrations never automatically unpause it. Changes already applied to
Outline are not reversed by disabling the worker.

## Sources checked

- [Outline v1.12.0 group API](https://github.com/outline/outline/blob/v1.12.0/server/routes/api/groups/groups.ts)
- [Outline v1.12.0 group presenter](https://github.com/outline/outline/blob/v1.12.0/server/presenters/group.ts)
- [Authentik 2026.5 LDAP connections](https://github.com/goauthentik/authentik/blob/version/2026.5.0/authentik/sources/ldap/api/connections.py)
- [Authentik 2026.5 source serializers](https://github.com/goauthentik/authentik/blob/version/2026.5.0/authentik/core/api/sources.py)
- [Temporal Python schedules](https://docs.temporal.io/develop/python/workflows/schedules)
