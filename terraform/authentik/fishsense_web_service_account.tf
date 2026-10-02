# FishSense web — service account for the public landing page (fishsense-services v2).
#
# v2's API validates bearer tokens itself (no forwardAuth outpost). The web's public
# landing page has no signed-in user, so it calls the API as THIS account: Authentik's
# machine-to-machine flow, `grant_type=client_credentials` against the web's own client
# (fishsense_oauth) carrying `username` + an APP PASSWORD (fishsense-services
# apps/web/lib/oidc.ts clientCredentialsToken). The token's `aud` is the web's client id,
# which the API already accepts; what the account may READ is decided in FishSense's own
# DB by a membership row on its `sub` (fishsense-services docs/cutover.md §3 step 4d) —
# Authentik only authenticates it.
#
# WHY a native Authentik service account (not an AD principal like svc_fishsense): it
# needs no domain resource — no NAS, no SMB, no LDAP bind — only this one OAuth client.
# A native `service_account` cannot log in interactively and carries no AD group, so it
# can't reach the other FishSense apps (analytics, API proxy) either. Its access to the
# web client is a direct USER binding below, not a group (so ADR 0013 §5 / "Authentik
# groups come from AD" is untouched — no local group is created).
#
# Grant prerequisites, both on fishsense_oauth (applications_e4e.tf): grant_types
# includes "client_credentials", and the user passes the application's policies.

resource "authentik_user" "svc_fishsense_web" {
  username = "svc-fishsense-web"
  name     = "FishSense web — public landing page (client_credentials)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  # No password: it authenticates only with the app password below.
}

# The app password the client_credentials grant validates. Non-expiring, matching the
# data-worker / outpost-token pattern (rotation is a follow-up); retrieve_key reads it
# back into (encrypted) state so it can be written to OpenBao.
resource "authentik_token" "fishsense_web_service_account" {
  identifier   = "fishsense-web-service-account-apppw"
  user         = authentik_user.svc_fishsense_web.id
  intent       = "app_password"
  expiring     = false
  retrieve_key = true
  description  = "FishSense web service account — client_credentials on fishsense-oauth for the public landing page (managed by terraform/authentik/fishsense_web_service_account.tf)"
}

# Authorize it on the web's application. OR-ed with the "FishSense" AD-group binding
# (app_access.tf) and the collaborator binding (order 10) under policy_engine_mode "any".
resource "authentik_policy_binding" "fishsense_web_service_account" {
  target = authentik_application.fishsense_oauth.uuid
  user   = authentik_user.svc_fishsense_web.id
  order  = 20
}

# Durable source of record, under the tenant's .../oidc/* — the ONLY tenant prefix the
# krg-deploy writer glob (`tenants/+/oidc`, terraform/openbao/main.tf) permits, so no
# privileged openbao apply is needed. The tenant AppRole already reads
# secret/data/tenants/fishsense/*. v2's secrets.nix currently reads
# `web_service_account` (owner-seeded); the owner either seeds that path FROM this one,
# or points the web.env render here (docs/handoff/fishsense-services/HANDOFF.md §3).
resource "vault_kv_secret_v2" "fishsense_web_service_account" {
  mount = "secret"
  name  = "tenants/fishsense/oidc/web-service-account"
  data_json = jsonencode({
    username = authentik_user.svc_fishsense_web.username
    password = authentik_token.fishsense_web_service_account.key
  })
}
