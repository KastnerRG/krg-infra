# E4E project applications.
# These are configured even when the upstream service isn't currently running —
# the OAuth2 registrations need to exist in Authentik before the services come up.

# ── E4E NAS ───────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "e4e_nas" {
  name                  = "Provider for E4E NAS"
  client_id             = "e4e-nas"
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://e4e-nas.ucsd.edu:6021" }]
  property_mappings     = local.std_scopes
  # RS256 signing key — DSM's SSO client verifies the ID token against jwks_uri.
  # Without a signing_key Authentik falls back to HS256 (symmetric) and serves an
  # empty JWKS, so DSM can't verify the token. Same fix as garage_ui (1f0875f).
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "e4e_nas" {
  name              = "E4E NAS"
  slug              = "e4e-nas"
  protocol_provider = authentik_provider_oauth2.e4e_nas.id
  meta_launch_url   = "https://e4e-nas.ucsd.edu:6021"
  meta_description  = "E4E network-attached storage"
  meta_icon         = "krg-icons/synology.svg"
}

# ── Garage UI (Noooste/garage-ui admin/data browser) ──────────────────────────
# client_id, slug, redirect URI, and issuer must match spec/e4e-nas/garage.yml
# `ui.oidc` exactly. The generated client_secret is captured into OpenBao at
# secret/e4e-nas/garage-ui-oidc (see vault_secrets.tf) — never hand-copied.
# Served on its own DNS name s3-admin.e4e.ucsd.edu (443), DSM AppPortal proxy:
#   redirect = <public_url>/auth/oidc/callback  (the UI auto-builds this path)
#   issuer   = ${authentik_url}/application/o/garage-ui/  (slug-derived)
# `groups` scope is added so garage-ui's group-based admin gate sees the claim.

# Stock Authentik ships no managed `groups` scope, so create one. Opt-in per
# provider (added to garage_ui below, not local.std_scopes) — most apps map
# groups→roles in their own config and don't need the raw claim. The expression
# emits the user's Authentik group names (AD-synced via the LDAP source).
resource "authentik_property_mapping_provider_scope" "groups" {
  name        = "OIDC Scope — groups (KRG)"
  scope_name  = "groups"
  description = "User's Authentik groups (AD-synced); consumed by app role gates (e.g. garage-ui)."
  expression  = <<-EOT
    return {
      "groups": [group.name for group in request.user.ak_groups.all()],
    }
  EOT
}

resource "authentik_provider_oauth2" "garage_ui" {
  name               = "Provider for Garage UI"
  client_id          = "garage-ui"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict",
  url = "https://s3-admin.e4e.ucsd.edu/auth/oidc/callback" }]
  property_mappings = concat(local.std_scopes,
  [authentik_property_mapping_provider_scope.groups.id])
  # RS256 signing key — REQUIRED for OIDC clients that verify the ID token
  # against jwks_uri (garage-ui / go-oidc). Without it Authentik falls back to
  # HS256 (symmetric) + an empty JWKS → "Invalid ID token". Use Authentik's
  # default self-signed cert.
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "garage_ui" {
  name              = "Garage UI"
  slug              = "garage-ui"
  protocol_provider = authentik_provider_oauth2.garage_ui.id
  meta_launch_url   = "https://s3-admin.e4e.ucsd.edu"
  meta_description  = "Garage S3 bucket/key admin + object browser"
  meta_icon         = "krg-icons/garage.svg"
}

# ── FishSense Workflows (Temporal) ────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_workflows" {
  name                   = "Provider for FishSense Workflows"
  client_id              = "fishsense-workflows"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://workflows.fishsense.e4e.ucsd.edu/auth/sso/callback" }]
  property_mappings      = local.std_scopes
  sub_mode               = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "fishsense_workflows" {
  name              = "FishSense Workflows"
  slug              = "fishsense-workflows"
  protocol_provider = authentik_provider_oauth2.fishsense_workflows.id
  meta_launch_url   = "https://workflows.fishsense.e4e.ucsd.edu"
  group             = "FishSense"
  open_in_new_tab   = true
}

# ── FishSense Analytics (Superset) ────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_analytics" {
  name                   = "Provider for FishSense Analytics"
  client_id              = "fishsense-analytics"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://analytics.fishsense.e4e.ucsd.edu/oauth-authorized/authentik" }]
  property_mappings      = local.std_scopes
  sub_mode               = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "fishsense_analytics" {
  name              = "FishSense Analytics"
  slug              = "fishsense-analytics"
  protocol_provider = authentik_provider_oauth2.fishsense_analytics.id
  meta_launch_url   = "https://analytics.fishsense.e4e.ucsd.edu"
  meta_icon         = "krg-icons/apache-superset.svg"
  group             = "FishSense"
}

# ── FishSense OAuth (main site) ───────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_oauth" {
  name                   = "Provider for FishSense OAuth"
  client_id              = "fishsense-oauth"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://fishsense.e4e.ucsd.edu/api/auth/callback/authentik" }]
  property_mappings      = local.std_scopes
  sub_mode               = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "fishsense_oauth" {
  name              = "FishSense"
  slug              = "fishsense-oauth"
  protocol_provider = authentik_provider_oauth2.fishsense_oauth.id
  meta_launch_url   = "https://fishsense.e4e.ucsd.edu"
  group             = "FishSense"
}

# ── FishSense Orchestrator (proxy) ────────────────────────────────────────────
# Uses a proxy provider — Authentik handles auth in front of the service.

resource "authentik_provider_proxy" "fishsense_orchestrator" {
  name               = "Provider for FishSense Orchestrator"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  external_host      = "https://orchestrator.fishsense.e4e.ucsd.edu"
  mode               = "forward_single"
}

resource "authentik_application" "fishsense_orchestrator" {
  name              = "FishSense Orchestrator"
  slug              = "fishsense-orchestrator"
  protocol_provider = authentik_provider_proxy.fishsense_orchestrator.id
  meta_launch_url   = "https://orchestrator.fishsense.e4e.ucsd.edu"
  group             = "FishSense"
}

# ── Qualcomm Docs (proxy) ─────────────────────────────────────────────────────

resource "authentik_provider_proxy" "qualcomm_docs" {
  name               = "Provider for Qualcomm Docs"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  external_host      = "https://qcomm.docs.fabricant.ucsd.edu"
  mode               = "forward_single"
}

resource "authentik_application" "qualcomm_docs" {
  name              = "Qualcomm Docs"
  slug              = "qualcomm-docs"
  protocol_provider = authentik_provider_proxy.qualcomm_docs.id
  meta_launch_url   = "https://qcomm.docs.fabricant.ucsd.edu"
  group             = "Qualcomm"
}

# ── KRG Roster ────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "e4e_roster" {
  name                   = "KRG Roster"
  client_id              = "e4e-roster"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://roster.krg.ucsd.edu/auth/callback" }]
  property_mappings      = local.std_scopes
  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "e4e_roster" {
  name              = "KRG Roster"
  slug              = "e4e-roster"
  protocol_provider = authentik_provider_oauth2.e4e_roster.id
  meta_launch_url   = "https://roster.e4e.ucsd.edu"
  meta_description  = "KRG lab roster and account management"
  group             = "KRG"
}
