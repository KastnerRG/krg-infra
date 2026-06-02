# E4E project applications.
# These are configured even when the upstream service isn't currently running —
# the OAuth2 registrations need to exist in Authentik before the services come up.

# ── E4E NAS ───────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "e4e_nas" {
  name               = "Provider for E4E NAS"
  client_id          = "e4e-nas"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://e4e-nas.ucsd.edu:6021" }]
  property_mappings  = local.std_scopes
  sub_mode           = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "e4e_nas" {
  name              = "E4E NAS"
  slug              = "e4e-nas"
  protocol_provider = authentik_provider_oauth2.e4e_nas.id
  meta_launch_url   = "https://e4e-nas.ucsd.edu:6021"
  meta_description  = "E4E network-attached storage"
}

# ── FishSense Workflows (Temporal) ────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_workflows" {
  name               = "Provider for FishSense Workflows"
  client_id          = "fishsense-workflows"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://workflows.fishsense.e4e.ucsd.edu/auth/sso/callback" }]
  property_mappings  = local.std_scopes
  sub_mode           = "hashed_user_id"
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
  name               = "Provider for FishSense Analytics"
  client_id          = "fishsense-analytics"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://analytics.fishsense.e4e.ucsd.edu/oauth-authorized/authentik" }]
  property_mappings  = local.std_scopes
  sub_mode           = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "fishsense_analytics" {
  name              = "FishSense Analytics"
  slug              = "fishsense-analytics"
  protocol_provider = authentik_provider_oauth2.fishsense_analytics.id
  meta_launch_url   = "https://analytics.fishsense.e4e.ucsd.edu"
  group             = "FishSense"
}

# ── FishSense OAuth (main site) ───────────────────────────────────────────────

resource "authentik_provider_oauth2" "fishsense_oauth" {
  name               = "Provider for FishSense OAuth"
  client_id          = "fishsense-oauth"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://fishsense.e4e.ucsd.edu/api/auth/callback/authentik" }]
  property_mappings  = local.std_scopes
  sub_mode           = "hashed_user_id"
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
  name               = "KRG Roster"
  client_id          = "e4e-roster"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://roster.e4e.ucsd.edu/auth/callback" }]
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
