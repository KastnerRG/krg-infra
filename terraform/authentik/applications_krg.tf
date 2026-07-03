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

  # Like std_scopes, but swaps the managed email scope for email_verified below
  # (asserts email_verified=true). Use for any app that federates AD/LDAP users
  # AND refuses SSO when the email_verified claim is false (Outline, Vaultwarden).
  std_scopes_verified = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.email_verified.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

# Shared verified-email OIDC scope. Authentik's MANAGED email scope reports
# email_verified=false for AD/LDAP-synced users (it never ran an email-verification
# flow against them), and some relying parties (Outline, Vaultwarden) refuse SSO —
# or refuse to provision a NEW user — unless email_verified is true. Our member
# emails are admin-entered from AD (known-good), so we assert verified here. This
# replaces the former Vaultwarden-specific `vaultwarden_email` scope so any future
# AD-federated app can reuse it via local.std_scopes_verified.
#
# Issue #185 tracks doing REAL email verification at Authentik and dropping this
# (and Vaultwarden's compose SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION flag, which only
# covers a *missing* claim, not an explicit false — which is why it didn't fix this).
resource "authentik_property_mapping_provider_scope" "email_verified" {
  name        = "OIDC Scope — email (verified, AD-federated)"
  scope_name  = "email"
  description = "Standard email claim, asserting email_verified=true (admin-entered AD emails)."
  expression  = <<-EOT
    return {
      "email": request.user.email,
      "email_verified": True,
    }
  EOT
}

# ── Grafana ────────────────────────────────────────────────────────────────────
# New SSO — was GitHub OAuth previously. Groups map to Grafana org roles via
# role_attribute_path in the grafana/ Terraform workspace.

resource "authentik_provider_oauth2" "grafana" {
  name                   = "Provider for Grafana"
  client_id              = "grafana"
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://monitoring.krg.ucsd.edu/login/generic_oauth" }]
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
  group             = "KRG Services"
}

# ── Outline ────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "outline" {
  name = "Provider for Outline"
  # client_secret is minted by terraform/secrets and read back here (it must exist
  # before the fail-closed krg-prod vault-agent renders it); client_id stays static.
  client_id          = "outline"
  client_secret      = data.vault_kv_secret_v2.outline_oidc.data["client_secret"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  # docs.krg.ucsd.edu (post DNS migration); Outline's OIDC callback path is
  # /auth/oidc.callback. Strict match → must equal the Host Outline is served on.
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://docs.krg.ucsd.edu/auth/oidc.callback" }]
  # std_scopes_verified (not std_scopes): Outline refuses to provision a NEW user
  # when email_verified is false, which Authentik reports for every AD/LDAP-synced
  # account — so first-time logins failed with "email address has not been verified"
  # while existing members were unaffected. See the email_verified scope above.
  property_mappings = local.std_scopes_verified
  # RS256 signing key — Outline (openid-client) verifies the ID token against the
  # provider's jwks_uri. Without it Authentik falls back to HS256 + empty JWKS →
  # "Invalid ID token" (the same failure garage-ui/vaultwarden/temporal/mlflow hit).
  signing_key            = data.authentik_certificate_key_pair.default.id
  sub_mode               = "user_email"
  access_token_validity  = "minutes=60"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "outline" {
  name              = "Outline"
  slug              = "outline"
  protocol_provider = authentik_provider_oauth2.outline.id
  meta_launch_url   = "https://docs.krg.ucsd.edu"
  meta_description  = "KRG lab wiki and documentation"
  meta_icon         = "krg-icons/outline.svg"
  group             = "KRG Services"
}

# ── MLflow ─────────────────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "mlflow" {
  name = "Provider for MLflow"
  # client_secret is minted by terraform/secrets and read back here (it must exist
  # before the fail-closed krg-prod vault-agent renders it); client_id stays static.
  client_id             = "mlflow"
  client_secret         = data.vault_kv_secret_v2.mlflow_oidc.data["client_secret"]
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://mlflow.krg.ucsd.edu/callback" }]
  # std_scopes ONLY — do NOT also add the explicit "groups (KRG)" scope here. The
  # managed `profile` scope (part of std_scopes) ALREADY emits a `groups` claim, so
  # requesting both makes Authentik concatenate the two → every group appears TWICE in
  # the claim. mlflow-oidc-auth's set_user_groups then inserts the same (user_id,
  # group_id) twice → unique-constraint violation on `user_groups` → the whole login
  # rolls back with "Failed to update user/groups". profile's groups claim already
  # carries the AD group names the access gate (OIDC_GROUP_NAME = "MLflow Users" /
  # OIDC_ADMIN_GROUP_NAME = "MLflow Admins") matches, so single-sourcing it is correct.
  # (Apps like vaultwarden/garage-ui add the explicit scope and tolerate the dupe
  # because they only read the claim; mlflow writes it into a UNIQUE-constrained table,
  # so it must be dup-free.)
  property_mappings = local.std_scopes
  # RS256 signing key — mlflow-oidc-auth (authlib) verifies the ID token against the
  # provider's jwks_uri. Without it Authentik falls back to HS256 + empty JWKS →
  # "Invalid ID token" (the same failure garage-ui/vaultwarden/temporal hit).
  signing_key            = data.authentik_certificate_key_pair.default.id
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
  group             = "KRG Services"
}

# ── Vaultwarden ──────────────────────────────────────────────────────────────────
# Lab password manager (vaultwarden.krg.ucsd.edu). SSO is login-federation only —
# vaults stay E2E-encrypted under each user's master password. The OIDC callback is
# auto-derived by Vaultwarden from its DOMAIN as <DOMAIN>/identity/connect/oidc-signin.
# The `groups` scope is wired now (AD-sourced) so Phase 2 (group→collection access,
# once upstream Vaultwarden supports it) needs no Authentik change. See
# docs/vaultwarden-sso.md.

resource "authentik_provider_oauth2" "vaultwarden" {
  name = "Provider for Vaultwarden"
  # client_secret is minted by terraform/secrets and read back here (it must exist
  # before the fail-closed krg-prod vault-agent renders it); client_id stays static.
  client_id             = "vaultwarden"
  client_secret         = data.vault_kv_secret_v2.vaultwarden_oidc.data["client_secret"]
  authorization_flow    = data.authentik_flow.default_authorization.id
  invalidation_flow     = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://vaultwarden.krg.ucsd.edu/identity/connect/oidc-signin" }]
  # Like std_scopes, but swaps the managed email scope for the shared email_verified
  # scope (asserts email_verified=true) + adds the AD-sourced groups scope.
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    authentik_property_mapping_provider_scope.email_verified.id,
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
  group            = "Access & Security"
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
  allowed_redirect_uris = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://remote.krg.ucsd.edu/" }]
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
  group             = "Access & Security"
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
  name = "Provider for Temporal"
  # client_secret is minted by terraform/secrets and read back here (it must exist
  # before the fail-closed krg-prod vault-agent renders it); client_id stays static.
  client_id              = "temporal"
  client_secret          = data.vault_kv_secret_v2.temporal_oidc.data["client_secret"]
  authorization_flow     = data.authentik_flow.default_authorization.id
  invalidation_flow      = data.authentik_flow.default_invalidation.id
  allowed_redirect_uris  = [{ matching_mode = "strict", redirect_uri_type = "authorization", url = "https://workflows.krg.ucsd.edu/auth/sso/callback" }]
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
  group             = "KRG Services"
  open_in_new_tab   = true
}

# ── Proxmox ────────────────────────────────────────────────────────────────────
# LINK-ONLY tile (no provider). Proxmox auth does NOT go through Authentik OIDC —
# the PVE web UI + the Proxmox mobile/CLI apps can't do the OIDC browser-redirect
# flow, so login is handled by a native PVE Active Directory realm against krg-ldap
# (ansible `pve_ad` role; AD group `proxmox-admins` → Administrator). This tile just
# keeps Proxmox visible+clickable on the Authentik dashboard (the lab launcher):
# clicking opens the PVE UI, where the user signs in with their KRG.LOCAL account.
#
# An application with no `protocol_provider` is a plain launch-URL bookmark — that's
# intentional here. See docs/proxmox-auth.md. (History: this was an OIDC app; the
# Authentik provider/scopes/secret were removed when auth moved to the AD realm —
# the goauthentik 2026.5 grant_types/ak_groups/evaluator quirks made OIDC group-sync
# more trouble than it was worth, and OIDC never served the apps anyway.)
resource "authentik_application" "proxmox" {
  name             = "Proxmox"
  slug             = "proxmox"
  meta_launch_url  = "https://fabricant.ucsd.edu:8006"
  meta_description = "Proxmox VE hypervisor management"
  meta_icon        = "krg-icons/proxmox.svg"
  group            = "Infrastructure"
  open_in_new_tab  = true
}
