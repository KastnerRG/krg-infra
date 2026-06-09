# Vaultwarden on krg-prod (Authentik SSO)

Vaultwarden (the lab password manager, `vaultwarden.krg.ucsd.edu`) runs as a
service in the **krg-prod** compose stack with **Authentik OIDC SSO** for login.
This is a **greenfield** deployment — no prior vaults are migrated.

- Service: [`nix/docker-compose/krg-prod/compose.vaultwarden.yml`](../nix/docker-compose/krg-prod/compose.vaultwarden.yml)
- Wired into the stack via `include:` in
  [`compose.yml`](../nix/docker-compose/krg-prod/compose.yml) + a Traefik alias.
- Host layout (data dir, compose symlink, required secrets) in
  [`nix/hosts/krg-prod/default.nix`](../nix/hosts/krg-prod/default.nix).
- Image pinned to `vaultwarden/server:1.36.0` (SSO landed upstream in 1.35.0).
- Backend: **SQLite** (`./vaultwarden/data/db.sqlite3` + `attachments/`, `sends/`,
  `rsa_key*`, `config.json`). Backup = copy that dir or use the `/admin` backup
  button — no `pg_dump`.

## AD-group → collection access: what works today vs. deferred

> The original goal was *"give users access to different collections based on AD
> group."* **Upstream Vaultwarden cannot do this yet.** Its built-in OIDC SSO only
> **authenticates** the login; it does not sync organization / group / collection
> membership from the OIDC `groups` claim. That sync lives only in the third-party
> **OIDCWarden** fork (Timshel). Per the deployment decision, we run the **official
> image** and wait for the upstream group PR (role PR dani-garcia/vaultwarden#6158
> is open; a group PR is planned after).

**Phase 1 (now):** AD users authenticate via Authentik SSO. Organization and
collection assignment is **manual** — an admin creates the Organization, creates
collections, and invites users / assigns collection access in the Vaultwarden org
UI (or `/admin`).

**Phase 2 (deferred, gated on upstream):** when upstream ships group→org sync, flip
it on via env vars (`SSO_SCOPES=email profile groups` + the org-sync vars upstream
defines). The Authentik provider **already emits the AD-sourced `groups` claim**
(see Terraform below), so this is a config change, not a redesign.

**IaC boundary (open item for Phase 2).** Vaultwarden's internal structure
(orgs / collections / org-users) is partially reachable by community Terraform
providers, but **the specific thing Phase 2 needs — groups and group→collection
access — is not** (see "Terraform for Vaultwarden's own config" below). Doing it in
the org UI is drift ([ADR 0001](adr/0001-iac-source-of-truth.md)); the IaC-clean
path is a script against the Bitwarden admin API / `bw` CLI, or extending a provider.
Decide the mechanism when Phase 2 lands — do not hand-click it as the fix.

## Terraform for Vaultwarden's own config

Two things people mean by "Terraform for Vaultwarden":

1. **The SSO integration (what this deployment uses, included in this PR).** The
   Authentik OIDC provider/application + the OpenBao `krg-prod/vaultwarden-oidc`
   secret, in `terraform/authentik/applications_krg.tf` + `vault_secrets.tf`. This
   is the only Terraform we add.

2. **Managing Vaultwarden's org/collection/user structure directly.** Two
   community providers exist, but **neither covers groups or group→collection
   access** — exactly the Phase-2 dimension — and both carry caveats, so we do
   **not** stand up a `terraform/vaultwarden/` root module yet:
   - **`ottramst/terraform-provider-vaultwarden`** (purpose-built, `admin_token`
     auth). Resources: `organization`, `organization_collection`,
     `organization_user`, `user`, `account_register`. **No group / group-access
     resource.** v0.4.4 declares support for Vaultwarden **1.28.x–1.32.x** — we run
     **1.36.0**, outside its tested range.
   - **`maxlaverse/bitwarden`** (`bw` CLI / embedded client, authenticates as a
     vault *account* with master password or API key). Resources include
     `org_collection` (can set collection member/permission), plus secret/item
     resources — but **no group resource**, and it's oriented to reading/writing
     secrets, not administering org structure.

   Both also require privileged live credentials (a DSM-style `admin_token` or a
   vault account master password) inside the IaC creds layer for a *password
   manager* — a sensitivity to weigh deliberately. Recommendation: revisit a
   `terraform/vaultwarden/` module alongside Phase 2 (when upstream group sync
   makes the group→collection mapping the real work); until then the Phase-1 access
   model is the manual org UI.

## Authentik + OpenBao Terraform (in this PR)

The OIDC provider/application and the OpenBao client-secret are part of this PR,
mirroring the **garage-ui** pattern (groups scope + RS256 signing key):

- [`terraform/authentik/applications_krg.tf`](../terraform/authentik/applications_krg.tf)
  — `authentik_provider_oauth2.vaultwarden` + `authentik_application.vaultwarden`
  (`slug = "vaultwarden"` → issuer `https://auth.krg.ucsd.edu/application/o/vaultwarden/`;
  redirect `…/identity/connect/oidc-signin`; `local.std_scopes` + the AD-sourced
  `groups` scope; RS256 `signing_key` — **required**, since Vaultwarden verifies the
  ID token against `jwks_uri`, else Authentik falls back to HS256 + empty JWKS →
  "Invalid ID token").
- [`terraform/authentik/vault_secrets.tf`](../terraform/authentik/vault_secrets.tf)
  — `vault_kv_secret_v2.vaultwarden_oidc` at `krg-prod/vaultwarden-oidc`.

Apply with the rest of `terraform/authentik/` (`tofu apply`); the client secret
lands in OpenBao, from which it's pulled into `.secrets/vaultwarden.env` (below).

> Gate *who* may reach the provider with an Authentik application policy bound to
> the appropriate AD group(s), so only intended AD users can SSO in.

## Secrets — `/var/lib/krg/krg-prod/.secrets/vaultwarden.env` (not in git)

```
ADMIN_TOKEN=<argon2 hash>     # `vaultwarden hash` (or argon2 a strong password) — gates /admin
SSO_CLIENT_SECRET=<secret>    # bao kv get -field=client_secret secret/krg-prod/vaultwarden-oidc
```

`DOMAIN`, `SSO_ENABLED`, `SSO_AUTHORITY`, `SSO_CLIENT_ID`, `SSO_SCOPES`,
`SIGNUPS_ALLOWED` are set inline (non-secret) in the compose file. `SSO_AUTHORITY`
is the **exact** Authentik app issuer (trailing slash, no
`/.well-known/openid-configuration`); the OIDC callback is auto-derived from
`DOMAIN` as `/identity/connect/oidc-signin`.

## Bring-up & verification

1. Apply `terraform/authentik/`; `tofu plan` should show
   only the new provider/application/secret.
2. `nix flake check ./nix` and deploy krg-prod
   (`nixos-rebuild switch --flake ./nix#krg-prod --target-host …`).
3. Populate `.secrets/vaultwarden.env` (pull `SSO_CLIENT_SECRET` from OpenBao;
   generate `ADMIN_TOKEN`).
4. Confirm the container is healthy: `docker compose ps`, `docker logs vaultwarden`.
5. Browse `https://vaultwarden.krg.ucsd.edu` → **Enterprise Single Sign-On** →
   redirects to Authentik → AD login → returns authenticated. Verify the user
   exists in `/admin`.
6. `/admin` reachable with `ADMIN_TOKEN`.
7. **Phase-1 access model:** create an Organization + collections and invite/assign
   a test AD user; confirm collection visibility.

## Notes

- **SSO ≠ no master password.** OIDC federates the *login identity*; the vault stays
  E2E-encrypted under each user's master password (no Key Connector). First SSO
  login still establishes a master password.
- **Signups are SSO-only.** `SIGNUPS_ALLOWED=false` blocks regular
  email+master-password registration, but the SSO flow still auto-creates accounts
  on first login (upstream 1.36), so accounts come **only via Authentik**. The real
  gate on *who* may sign up is the Authentik application policy — bind it to an AD
  group; Vaultwarden does not enforce it.
- **Email verification.** Authentik's managed email scope reports
  `email_verified: false` for AD/LDAP-synced users (it never verified the address),
  and Vaultwarden refuses login on `email_verified != true`. The compose flag
  `SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=true` does **not** fix this — it only allows
  a *missing* claim, not an explicit `false`. The actual fix is the custom
  `vaultwarden_email` OIDC scope in `terraform/authentik` that asserts
  `email_verified: true` (safe: member emails are admin-entered, known-good). Issue
  #185 tracks doing real email verification at Authentik and dropping both.
- **Stable subject.** The provider uses `sub_mode = "hashed_user_id"` (not the
  email) so identity doesn't ride on a mutable, admin-managed email — changing an
  email won't orphan or collide a user's vault.
- **Login UX — skip the "SSO identifier" page.** Bitwarden's web vault prompts for
  an org SSO identifier before redirecting to the IdP; Vaultwarden has one global
  OIDC provider, so that identifier is a fixed dummy
  (`00000000-01DC-01DC-01DC-000000000000`). The Authentik application's
  `meta_launch_url` is set to the deep-link
  `https://vaultwarden.krg.ucsd.edu/#/sso?identifier=00000000-01DC-01DC-01DC-000000000000`,
  so launching from the Authentik dashboard (or bookmarking that URL) skips the
  identifier page. `SSO_ONLY` is deliberately **left off** — forcing SSO would drop
  master-password login, chaining vault availability to Authentik (bad for a
  password manager during an IdP outage). A residual redundant email-entry step may
  remain until an upstream web-client fix (dani-garcia/vaultwarden#7207).
- Prometheus already probes `https://vaultwarden.krg.ucsd.edu/` — no scrape change.
- DNS CNAME for `vaultwarden.krg` is published at the DNS layer (not this repo).
