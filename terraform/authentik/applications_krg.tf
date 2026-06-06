# KRG lab-wide applications — hosted on krg-prod.
# All use OAuth2/OIDC with implicit consent (internal lab services).

locals {
  std_scopes = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

# ── Grafana ────────────────────────────────────────────────────────────────────
# New SSO — was GitHub OAuth previously. Groups map to Grafana org roles via
# role_attribute_path in the grafana/ Terraform workspace.

resource "authentik_provider_oauth2" "grafana" {
  name               = "Provider for Grafana"
  client_id          = "grafana"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://dashboard.waiter.ucsd.edu/login/generic_oauth" }]
  property_mappings  = local.std_scopes
  sub_mode           = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://dashboard.waiter.ucsd.edu"
  meta_description  = "KRG lab metrics and dashboards"
  group             = "KRG"
}

# ── Outline ────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "outline" {
  name               = "Provider for Outline"
  client_id          = "outline"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://wiki.fabricant.ucsd.edu/auth/oidc.callback" }]
  property_mappings  = local.std_scopes
  sub_mode           = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "outline" {
  name              = "Outline"
  slug              = "outline"
  protocol_provider = authentik_provider_oauth2.outline.id
  meta_launch_url   = "https://wiki.fabricant.ucsd.edu"
  meta_description  = "KRG lab wiki and documentation"
  group             = "KRG"
}

# ── MLflow ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "mlflow" {
  name               = "Provider for MLflow"
  client_id          = "mlflow"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://mlflow.krg.ucsd.edu/callback" }]
  property_mappings  = local.std_scopes
  sub_mode           = "user_username"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "mlflow" {
  name              = "MLflow"
  slug              = "mlflow"
  protocol_provider = authentik_provider_oauth2.mlflow.id
  meta_launch_url   = "https://mlflow.krg.ucsd.edu"
  meta_description  = "ML experiment tracking"
  group             = "KRG"
}

# ── Vaultwarden ──────────────────────────────────────────────────────────────────
# Lab password manager (vaultwarden.krg.ucsd.edu). SSO is login-federation only —
# vaults stay E2E-encrypted under each user's master password. The OIDC callback is
# auto-derived by Vaultwarden from its DOMAIN as <DOMAIN>/identity/connect/oidc-signin.
# The `groups` scope is wired now (AD-sourced) so Phase 2 (group→collection access,
# once upstream Vaultwarden supports it) needs no Authentik change. See
# docs/vaultwarden-sso.md.

resource "authentik_provider_oauth2" "vaultwarden" {
  name               = "Provider for Vaultwarden"
  client_id          = "vaultwarden"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://vaultwarden.krg.ucsd.edu/identity/connect/oidc-signin" }]
  property_mappings = concat(local.std_scopes,
    [authentik_property_mapping_provider_scope.groups.id])
  # RS256 signing key — REQUIRED: Vaultwarden verifies the ID token against jwks_uri.
  # Without it Authentik falls back to HS256 + empty JWKS → "Invalid ID token" (the
  # same failure garage-ui hit).
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "vaultwarden" {
  name              = "Vaultwarden"
  slug              = "vaultwarden"
  protocol_provider = authentik_provider_oauth2.vaultwarden.id
  meta_launch_url   = "https://vaultwarden.krg.ucsd.edu"
  meta_description  = "KRG lab password manager"
  group             = "KRG"
}

# ── Proxmox ────────────────────────────────────────────────────────────────────
# Commented out — Proxmox auth is currently managed via Ansible/PVE realm config.
# Uncomment when ready to bring SSO login to the PVE web UI under IaC.
#
# resource "authentik_provider_oauth2" "proxmox" {
#   name               = "Provider for Proxmox"
#   client_id          = "proxmox"
#   authorization_flow = data.authentik_flow.default_authorization.id
#   invalidation_flow  = data.authentik_flow.default_invalidation.id
#   redirect_uris = [
#     "https://fabricant.ucsd.edu:8006",
#     "https://synthesis.ucsd.edu:8006",
#   ]
#   property_mappings      = local.std_scopes
#   sub_mode               = "user_email"
#   access_token_validity  = "hours=1"
#   refresh_token_validity = "days=30"
# }
#
# resource "authentik_application" "proxmox" {
#   name              = "Proxmox"
#   slug              = "proxmox"
#   protocol_provider = authentik_provider_oauth2.proxmox.id
#   meta_launch_url   = "https://fabricant.ucsd.edu:8006"
#   meta_description  = "Proxmox VE hypervisor management"
#   group             = "Virtual Machines"
# }
