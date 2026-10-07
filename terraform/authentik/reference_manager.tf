# E4E Reference Manager — bib.krg.ucsd.edu (github.com/UCSD-E4E/e4e-reference-manager).
#
# An Incus TENANT (`reference-manager`, the first KRG-zone one): the app runs on its
# own slot behind the krg-prod edge, so — like FishSense — its OIDC client secret is
# written UNDER the tenant's KV (secret/tenants/reference-manager/oidc/web), which its
# tenant AppRole reads and krg-deploy may write via the `tenants/+/oidc` glob
# (terraform/openbao main.tf). No openbao apply is needed for this file.
#
# The app's API does the OIDC dance itself (authlib, api/app/auth.py): confidential
# client, authorization-code flow, callback on the API under /api. It reads `sub`
# (its user key), `email`, `name`, and the `groups` claim (OIDC_GROUPS_CLAIM, default
# "groups") from the ID token, creating a group per name and granting org admin to
# OIDC_ADMIN_GROUP members. Group names reach the token ONLY via the KRG `groups` scope
# mapping (applications_e4e.tf) AND only if the app ASKS for scope `groups`; today it
# requests "openid email profile", so group sync sees [] until it adds `groups`
# (tracked as an app change in docs/onboarding-reference-manager.md).

resource "authentik_provider_oauth2" "reference_manager" {
  name               = "Provider for E4E Reference Manager"
  client_id          = "reference-manager"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  # The API serves under /api (uvicorn --root-path /api behind the inner Traefik), so
  # its /auth/callback route is public at /api/auth/callback. Must equal the app's
  # REFMAN_OIDC_REDIRECT_URI byte-for-byte (strict match).
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://bib.krg.ucsd.edu/api/auth/callback" }]
  # openid/email/profile (std_scopes) + the KRG `groups` scope: request-to-receive, so
  # it's inert until the app asks for it (see the header).
  property_mappings = concat(local.std_scopes, [
    authentik_property_mapping_provider_scope.groups.id,
  ])
  # Set explicitly: goauthentik 2026.x defaults grant_types EMPTY on create. The app
  # only does the browser login (no refresh tokens, no service account).
  grant_types = ["authorization_code"]
  # RS256 with the default keypair, so the ID token verifies against the published
  # JWKS (authlib's default). Without a signing_key Authentik signs HS256 with the
  # client secret and serves an empty JWKS (the #491 class of bug).
  signing_key = data.authentik_certificate_key_pair.default.id
  # The app keys users on `sub`, so it must be stable per user: hashed_user_id (the
  # repo default for tenants). Changing it later orphans every existing user row.
  sub_mode = "hashed_user_id"
}

resource "authentik_application" "reference_manager" {
  name = "E4E Reference Manager"
  # slug is load-bearing: the issuer is /application/o/<slug>/ (REFMAN_OIDC_ISSUER,
  # rendered from oidc/web.issuer_url below).
  slug              = "reference-manager"
  protocol_provider = authentik_provider_oauth2.reference_manager.id
  meta_launch_url   = "https://bib.krg.ucsd.edu"
  meta_description  = "Shared bibliography + PDF library (Zotero-style) for the lab"
  meta_icon         = "krg-icons/reference-manager.svg"
  group             = "KRG Services"
  # No app_access.tf binding: every authenticated realm user may sign in (the app's
  # own groups + sharing decide what they see). Add one there to restrict it.
}

# Read by the tenant's in-VM vault-agent (the interior's secrets.nix) into the API's
# env: REFMAN_OIDC_CLIENT_ID / _CLIENT_SECRET / _ISSUER.
resource "vault_kv_secret_v2" "reference_manager_oidc_web" {
  mount = "secret"
  name  = "tenants/reference-manager/oidc/web"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.reference_manager.client_id
    client_secret = authentik_provider_oauth2.reference_manager.client_secret
    issuer_url    = "${var.authentik_url}/application/o/reference-manager/"
  })
}
