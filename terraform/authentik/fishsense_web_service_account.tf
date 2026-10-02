# FishSense web — the public landing page's API credential (fishsense-services v2).
#
# v2's API validates bearer tokens itself (no forwardAuth outpost). The web's public
# landing page has no signed-in user, so it calls the API as svc_fishsense: Authentik's
# machine-to-machine flow, `grant_type=client_credentials` against the web's own client
# (fishsense_oauth) carrying `username` + an APP PASSWORD (fishsense-services
# apps/web/lib/oidc.ts clientCredentialsToken). The token's `aud` is the web's client id,
# which the API already accepts; what the account may READ is decided in FishSense's own
# DB by a membership row on its `sub` (fishsense-services docs/cutover.md §3 step 4d) —
# Authentik only authenticates it.
#
# WHY svc_fishsense (not a dedicated web account): one FishSense service identity is
# simpler to run than two, and the exposure is about the same. The web holds an Authentik
# APP PASSWORD, not the AD password, so it can't reach the NAS (svc_fishsense's real job,
# via FishSense-Prod-Admins / FishSense-NAS — unchanged). Its "FishSense" membership
# already passes the web app's access binding (app_access.tf: fishsense_oauth =
# ["FishSense"]), so no new binding. Residual coupling, accepted: an AD lockout or
# disable of svc_fishsense breaks the landing page's API calls (sign-in is unaffected).
#
# Grant prerequisite on fishsense_oauth (applications_e4e.tf): grant_types includes
# "client_credentials".

# svc_fishsense is a real KRG.LOCAL service account (spec/krg-ad/service-accounts.yml)
# synced into Authentik by the samba_ad LDAP source (ldap.tf), with its FishSense groups.
data "authentik_user" "svc_fishsense" {
  username = "svc_fishsense" # sAMAccountName as synced by the samba_ad source
}

# Its own token (not the data-worker's): rotated / revoked independently, and the
# data-worker one was retired with v1's API proxy. Non-expiring, matching the
# data-worker / outpost-token pattern (rotation is a follow-up); retrieve_key reads it
# back into (encrypted) state so it can be written to OpenBao.
resource "authentik_token" "fishsense_web_service_account" {
  identifier   = "fishsense-web-service-account-apppw"
  user         = data.authentik_user.svc_fishsense.id
  intent       = "app_password"
  expiring     = false
  retrieve_key = true
  description  = "FishSense web landing page — client_credentials on fishsense-oauth as svc_fishsense (managed by terraform/authentik/fishsense_web_service_account.tf)"
}

# Read by v2's web.env render (fishsense-services deploy/incus/secrets.nix). Under the
# tenant's .../oidc/* — the ONLY tenant prefix the krg-deploy writer glob
# (`tenants/+/oidc`, terraform/openbao/main.tf) permits, so no privileged openbao apply.
# The tenant AppRole already reads secret/data/tenants/fishsense/*.
resource "vault_kv_secret_v2" "fishsense_web_service_account" {
  mount = "secret"
  name  = "tenants/fishsense/oidc/web-service-account"
  data_json = jsonencode({
    username = data.authentik_user.svc_fishsense.username
    password = authentik_token.fishsense_web_service_account.key
  })
}
