# E4E project applications.
# These are configured even when the upstream service isn't currently running —
# the OAuth2 registrations need to exist in Authentik before the services come up.

# ── E4E NAS ───────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "e4e_nas" {
  name                  = "Provider for E4E NAS"
  client_id             = "e4e-nas"
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://e4e-nas.ucsd.edu:6021" }]
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
  group             = "E4E Storage"
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
      "groups": [group.name for group in request.user.groups.all()],
    }
  EOT
}

resource "authentik_provider_oauth2" "garage_ui" {
  name               = "Provider for Garage UI"
  client_id          = "garage-ui"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization",
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
  # Display name only — slug/client_id stay "garage-ui" (load-bearing: issuer URL
  # + OpenBao secret path secret/e4e-nas/garage-ui-oidc, see vault_secrets.tf).
  name              = "E4E Garage UI"
  slug              = "garage-ui"
  protocol_provider = authentik_provider_oauth2.garage_ui.id
  meta_launch_url   = "https://s3-admin.e4e.ucsd.edu"
  meta_description  = "Garage S3 bucket/key admin + object browser"
  meta_icon         = "krg-icons/garage.svg"
  group             = "E4E Storage"
}

# ── FishSense Analytics (Superset) ────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_analytics" {
  name                   = "Provider for FishSense Analytics"
  client_id              = "fishsense-analytics"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://analytics.fishsense.e4e.ucsd.edu/oauth-authorized/authentik" }]
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
  group             = "E4E FishSense"
}

# ── FishSense OAuth (main site) ───────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_oauth" {
  name                   = "Provider for FishSense OAuth"
  client_id              = "fishsense-oauth"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://fishsense.e4e.ucsd.edu/api/auth/callback/authentik" }]
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
  meta_icon         = "krg-icons/fishsense.svg"
  group             = "E4E FishSense"
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
  # Reuse the FishSense brand mark — no orchestrator-specific logo exists (same
  # pattern as guacamole_gate reusing guacamole.svg).
  meta_icon = "krg-icons/fishsense.svg"
  group     = "E4E FishSense"
}

# ── KRG Roster ────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "e4e_roster" {
  name                  = "KRG Roster"
  client_id             = "e4e-roster"
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://roster.krg.ucsd.edu/auth/callback" }]
  property_mappings     = local.std_scopes
  # RS256 signing key — without this Authentik uses HS256 + empty JWKS, which
  # broke after the 2026.2→2026.5 upgrade (same fix as guacamole/vaultwarden).
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "e4e_roster" {
  name              = "KRG Roster"
  slug              = "e4e-roster"
  protocol_provider = authentik_provider_oauth2.e4e_roster.id
  meta_launch_url   = "https://roster.krg.ucsd.edu/login"
  meta_description  = "KRG lab roster and account management"
  group             = "Infrastructure"
}

# ── Fleet (device management / MDM) ───────────────────────────────────────────
# mdm.e4e.ucsd.edu — the lab-owned MDM control plane (ADR 0012). Fleet's console
# SSO is SAML 2.0 ONLY (every other app here is OIDC) — hence the repo's first
# authentik_provider_saml. Fleet keys each user on the SAML NameID and REQUIRES it
# to be the user's email address, so NameID = the default Email mapping. (Caveat:
# our AD emails are admin-managed; treat them as stable while Fleet uses them as the
# identity handle — same concern noted on the vaultwarden sub_mode.)
#
# HARDENING FOLLOW-UP: Fleet is the device control plane — restrict console access to
# a Fleet-admins AD group via an authentik_policy_binding (see [[ad-structure-is-iac]]),
# rather than leaving it open to all authenticated users. JIT role-mapping is Fleet
# Premium (see fleet/sso_settings in docs/fleet-mdm.md).
resource "authentik_provider_saml" "fleet" {
  name               = "Provider for Fleet"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  # Fleet's Assertion Consumer Service endpoint (the SAML callback).
  acs_url = "https://mdm.e4e.ucsd.edu/api/v1/fleet/sso/callback"
  # Audience MUST equal Fleet's configured entity_id (fleet sso_settings).
  audience   = "https://mdm.e4e.ucsd.edu"
  sp_binding = "post"
  # No issuer override: authentik auto-generates the IdP issuer/EntityID, and Fleet
  # reads it from the metadata_url it's pointed at (docs/fleet-mdm.md). The SAML
  # provider has `issuer_override` (not `issuer`); we don't need to override it.
  # Sign assertions with Authentik's default keypair; Fleet verifies against the IdP
  # signing cert published in the metadata_url it's pointed at.
  signing_kp      = data.authentik_certificate_key_pair.default.id
  name_id_mapping = data.authentik_property_mapping_provider_saml.email.id
  property_mappings = [
    data.authentik_property_mapping_provider_saml.email.id,
    data.authentik_property_mapping_provider_saml.username.id,
    data.authentik_property_mapping_provider_saml.name.id,
  ]
}

resource "authentik_application" "fleet" {
  name = "Fleet"
  # slug is load-bearing: the SAML metadata URL embeds /application/saml/fleet/
  # (fleet sso_settings metadata_url — docs/fleet-mdm.md).
  slug              = "fleet"
  protocol_provider = authentik_provider_saml.fleet.id
  meta_launch_url   = "https://mdm.e4e.ucsd.edu"
  meta_description  = "Lab device management / MDM (lab-owned endpoints)"
  meta_icon         = "krg-icons/fleet.svg"
  group             = "Access & Security"
}
