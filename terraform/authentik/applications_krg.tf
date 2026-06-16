# KRG lab-wide applications — hosted on krg-prod.
# All use OAuth2/OIDC with implicit consent (internal lab services).
#
# meta_icon = "krg-icons/<file>.svg" references SVGs bind-mounted into Authentik's
# media store on krg-prod — see nix/docker-compose/krg-prod/authentik/media-icons/.

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
  name                   = "Provider for Grafana"
  client_id              = "grafana"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://monitoring.krg.ucsd.edu/login/generic_oauth" }]
  property_mappings      = local.std_scopes
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://monitoring.krg.ucsd.edu"
  meta_description  = "KRG lab metrics and dashboards"
  meta_icon         = "krg-icons/grafana.svg"
  group             = "KRG"
}

# ── Outline ────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "outline" {
  name                   = "Provider for Outline"
  client_id              = "outline"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://wiki.fabricant.ucsd.edu/auth/oidc.callback" }]
  property_mappings      = local.std_scopes
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "outline" {
  name              = "Outline"
  slug              = "outline"
  protocol_provider = authentik_provider_oauth2.outline.id
  meta_launch_url   = "https://wiki.fabricant.ucsd.edu"
  meta_description  = "KRG lab wiki and documentation"
  meta_icon         = "krg-icons/outline.svg"
  group             = "KRG"
}

# ── MLflow ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "mlflow" {
  name                   = "Provider for MLflow"
  client_id              = "mlflow"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://mlflow.krg.ucsd.edu/callback" }]
  property_mappings      = local.std_scopes
  sub_mode               = "user_username"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "mlflow" {
  name              = "MLflow"
  slug              = "mlflow"
  protocol_provider = authentik_provider_oauth2.mlflow.id
  meta_launch_url   = "https://mlflow.krg.ucsd.edu"
  meta_description  = "ML experiment tracking"
  meta_icon         = "krg-icons/mlflow.svg"
  group             = "KRG"
}

# ── Vaultwarden ──────────────────────────────────────────────────────────────────
# Lab password manager (vaultwarden.krg.ucsd.edu). SSO is login-federation only —
# vaults stay E2E-encrypted under each user's master password. The OIDC callback is
# auto-derived by Vaultwarden from its DOMAIN as <DOMAIN>/identity/connect/oidc-signin.
# The `groups` scope is wired now (AD-sourced) so Phase 2 (group→collection access,
# once upstream Vaultwarden supports it) needs no Authentik change. See
# docs/vaultwarden-sso.md.

# Custom email scope: Authentik's managed email scope reports email_verified=false
# for AD/LDAP-synced users (it never verified the address), and Vaultwarden refuses
# SSO login unless email_verified is true. Our member emails are admin-entered
# (known-good), so assert verified here. Issue #185 tracks doing real email
# verification at Authentik and dropping this (and the compose
# SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION flag, which only covers a *missing* claim,
# not an explicit false — which is why it didn't fix this).
resource "authentik_property_mapping_provider_scope" "vaultwarden_email" {
  name        = "OIDC Scope — email (verified, Vaultwarden)"
  scope_name  = "email"
  description = "Standard email claim, asserting email_verified=true (admin-entered AD emails)."
  expression  = <<-EOT
    return {
      "email": request.user.email,
      "email_verified": True,
    }
  EOT
}

resource "authentik_provider_oauth2" "vaultwarden" {
  name                  = "Provider for Vaultwarden"
  client_id             = "vaultwarden"
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://vaultwarden.krg.ucsd.edu/identity/connect/oidc-signin" }]
  # Like std_scopes, but swaps the managed email scope for vaultwarden_email
  # (asserts email_verified=true) + adds the AD-sourced groups scope.
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.vaultwarden_email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    authentik_property_mapping_provider_scope.groups.id,
  ]
  # RS256 signing key — REQUIRED: Vaultwarden verifies the ID token against jwks_uri.
  # Without it Authentik falls back to HS256 + empty JWKS → "Invalid ID token" (the
  # same failure garage-ui hit).
  signing_key = data.authentik_certificate_key_pair.default.id
  # Stable, opaque subject — do NOT key identity on the email. Emails are
  # admin-managed and can change; tying `sub` to the email would orphan or
  # collide a user's vault if it's ever edited.
  sub_mode               = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "vaultwarden" {
  name              = "Vaultwarden"
  slug              = "vaultwarden"
  protocol_provider = authentik_provider_oauth2.vaultwarden.id
  # Deep-link into Vaultwarden's SSO start with the (fixed dummy) org identifier
  # pre-filled, so launching from the Authentik dashboard skips the Bitwarden
  # "enter SSO identifier" page. Vaultwarden has one global OIDC provider, so the
  # identifier is a constant for everyone. See docs/vaultwarden-sso.md.
  meta_launch_url  = "https://vaultwarden.krg.ucsd.edu/#/sso?identifier=00000000-01DC-01DC-01DC-000000000000"
  meta_description = "KRG lab password manager"
  meta_icon        = "krg-icons/vaultwarden.svg"
  group            = "KRG"
}

# ── Guacamole ────────────────────────────────────────────────────────────────────
# Remote-desktop / SSH gateway at remote.krg.ucsd.edu. Two gates (defense-in-depth):
#   INNER — this OIDC provider (Guacamole's native OpenID Connect, implicit flow).
#   OUTER — the guacamole_gate proxy provider below (forward-auth on the outpost),
#           so no unauthenticated request reaches Guacamole's Tomcat.
# Guacamole's Postgres DB holds the connection inventory + per-user authz.

resource "authentik_provider_oauth2" "guacamole" {
  name                  = "Provider for Guacamole"
  client_id             = "guacamole"
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", url = "https://remote.krg.ucsd.edu/" }]
  # std scopes + the AD-sourced `groups` scope so Guacamole receives the user's AD
  # group names (claim "groups"). Drives admin + per-connection access via matching
  # Guacamole user-groups (e.g. "Guacamole Admins" → ADMINISTER, "Waiter" → the
  # waiter connection). The webapp sets OPENID_SCOPE=...groups + OPENID_GROUPS_CLAIM_TYPE.
  property_mappings = concat(local.std_scopes, [authentik_property_mapping_provider_scope.groups.id])
  # RS256 signing key — REQUIRED: Guacamole verifies the ID token against the JWKS
  # endpoint (openid-jwks-endpoint). Without it Authentik falls back to HS256 + an
  # empty JWKS → "Invalid ID token" (the failure vaultwarden/garage-ui hit).
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "guacamole" {
  name = "Guacamole"
  # slug is load-bearing: the issuer/jwks env vars in compose.guacamole.yml embed
  # /application/o/guacamole/.
  slug              = "guacamole"
  protocol_provider = authentik_provider_oauth2.guacamole.id
  meta_launch_url   = "https://remote.krg.ucsd.edu"
  meta_description  = "Remote desktop / SSH gateway"
  meta_icon         = "krg-icons/guacamole.svg"
  group             = "KRG"
}

# OUTER forward-auth gate. A SEPARATE Authentik application from the OIDC one above
# (the proxy provider backs the gate; access policy binds to this application). No
# meta_launch_url → kept out of the user library so there aren't two "Guacamole"
# tiles. Registered on the proxy outpost in outpost.tf; the `authentik` Traefik
# middleware (compose.authentik.yml) enforces it on the guacamole router.
resource "authentik_provider_proxy" "guacamole_gate" {
  name               = "Forward-auth gate for Guacamole"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  external_host      = "https://remote.krg.ucsd.edu"
  mode               = "forward_single"
}

resource "authentik_application" "guacamole_gate" {
  name              = "Guacamole (gateway)"
  slug              = "guacamole-gate"
  protocol_provider = authentik_provider_proxy.guacamole_gate.id
  # Reuse the Guacamole logo so the gate reads correctly in the admin app list.
  # Icon only — NO meta_launch_url/group, so it stays out of the user library (see
  # the gate comment above: avoid a second "Guacamole" tile).
  meta_icon = "krg-icons/guacamole.svg"
}

# ── Temporal ─────────────────────────────────────────────────────────────────────
# Lab-wide workflow engine at workflows.krg.ucsd.edu (was FishSense-specific
# workflows.fishsense.e4e.ucsd.edu). The Temporal Web UI is the OIDC client; its
# go-oidc verifies the ID token against jwks_uri, so this carries an RS256
# signing_key — without it Authentik falls back to HS256 + an empty JWKS →
# "Invalid ID token" (the failure guacamole/vaultwarden/garage-ui hit). The
# callback path /auth/sso/callback is temporal-ui's default. Consumed by
# nix/docker-compose/krg-prod/compose.temporal.yml.

resource "authentik_provider_oauth2" "temporal" {
  name                   = "Provider for Temporal"
  client_id              = "temporal"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", url = "https://workflows.krg.ucsd.edu/auth/sso/callback" }]
  property_mappings      = local.std_scopes
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "hashed_user_id"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "temporal" {
  name              = "Temporal"
  slug              = "temporal"
  protocol_provider = authentik_provider_oauth2.temporal.id
  meta_launch_url   = "https://workflows.krg.ucsd.edu"
  meta_description  = "KRG lab workflow engine"
  meta_icon         = "krg-icons/temporal.svg"
  group             = "KRG"
  open_in_new_tab   = true
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
