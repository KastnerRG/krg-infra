# Invite an outside collaborator to SSO

Use this runbook to issue an individual invitation for an outside-UCSD
collaborator who needs access to a project's web applications. They do not need a
UCSD email address. Enrollment creates an Authentik-local `external` account;
it does not create an AD account or grant host, compute, or storage access.

For lab members who need an AD account, see [creating a user](creating-a-user.md).
The trust model is described in [ADR 0013](adr/0013-sso-authentik-front-door.md).

## Before creating the invitation

You need administrator access to [Authentik](https://auth.krg.ucsd.edu/if/admin/),
the collaborator's email address, and their project tenant and partner org ID.
Confirm those values with the project owner. The configured tenant grants are:

| Tenant | Applications | Example partner org ID |
|---|---|---|
| `fishsense` | FishSense web, mobile, and analytics (Superset) | `conservation-angler`, `reef`, `ccfrp-ucsd` |
| `frog-id` | Label Studio | `australian-museum` |

The authoritative grants are in
[`collaborator_tenants.tf`](../terraform/authentik/collaborator_tenants.tf).
Creating an invitation with a new tenant name does not configure application
access; new tenant grants require an infrastructure change. Applications enforce
their own organization/workspace isolation and roles.

## Create a single-use invitation

1. In Authentik Admin, go to **Directory → Invitations → Create**.
2. Select the flow **`krg-collaborator-enrollment`**.
3. Enable **Single use** and set an expiration appropriate for the onboarding.
4. In **Custom attributes**, enter the tenant, partner org ID, and invited email.
   For an Australian Museum collaborator using Frog ID, for example:

   ```json
   {
     "attributes.tenant": "frog-id",
     "attributes.org": "australian-museum",
     "attributes.invited_email": "person@example.org"
   }
   ```

   For FishSense, use `fishsense` as the tenant and the collaborator's partner org
   ID. Keep the literal `attributes.` prefixes: the enrollment flow uses these
   keys to persist the values on the new account.

   Set `attributes.invited_email` for every individual invite. The email field is
   prefilled, enrollment requires that address (case-insensitive), and email
   verification proves mailbox ownership.

5. Save the invitation and send its enrollment URL privately to the invitee:

   ```text
   https://auth.krg.ucsd.edu/if/flow/krg-collaborator-enrollment/?itoken=<token>
   ```

   Replace `<token>` with the invitation token. The bare flow URL does not allow
   enrollment without a valid invitation.

Individual invitations are an intentional UI-managed exception. Do not add them
to `collaborator_invites.tf`: Authentik deletes a single-use invitation when it is
redeemed, and a subsequent infrastructure deployment would recreate a
code-managed invitation with a fresh token. See the
[Authentik invitation reference](../terraform/authentik/README.md#minting-a-one-off-invite-per-person)
for details and the separate reusable-invitation workflow.

## What the collaborator does

1. Open the invitation while logged out of Authentik, or use a private browser
   window. The enrollment flow requires an unauthenticated session.
2. Enter their full name, choose a username and password, and use the email
   address bound to the invitation.
3. Open the confirmation email and follow its link within **30 minutes**. The
   account remains inactive until this verification succeeds.
4. After enrollment signs them in, open the project's application and check that
   the expected organization or workspace is available.

For Frog ID, verify the partner's workspace and role using the
[Label Studio SSO runbook](label-studio-sso.md#external-collaborators-partner-orgs).
The collaborator account does not grant access to the roster or other
members-only applications.

## Troubleshooting

- **Already signed in:** log out or open the invitation in a private window.
- **Invitation expired or already used:** check whether the account already
  exists before issuing a replacement. A redeemed invitation cannot be reused.
- **Different-email error:** confirm the intended address with the project owner;
  issue a correctly bound invitation if necessary.
- **Confirmation email missing or expired:** check spam and Authentik's email
  delivery before retrying verification. The account is inactive until verified.
- **Sign-in works but the app is unavailable:** check the account's `tenant` and
  `org` attributes against the invitation and configured tenant grants, then
  check the application's organization/workspace mapping. Do not grant AD groups
  as a workaround for web-only collaborator access.
