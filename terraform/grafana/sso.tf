# Read the OIDC credentials written by the authentik workspace.
data "vault_kv_secret_v2" "grafana_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/grafana-oidc"
}

# Configure Grafana generic OAuth SSO via Authentik.
# Role mapping: Domain Admins → GrafanaAdmin, everyone else → Viewer.
# (Domain Admins comes through LDAP sync from Samba AD verbatim, and is also
#  flagged is_superuser in Authentik via a group property mapping — see
#  terraform/authentik/groups.tf. Either way the GrafanaAdmin mapping below keys
#  off the group NAME in the `groups` claim, not Authentik's superuser bit.)
# Grafana evaluates role_attribute_path as JMESPath against the userinfo claims;
# Authentik includes `groups` in the profile scope.
resource "grafana_sso_settings" "authentik" {
  provider_name = "generic_oauth"

  oauth2_settings {
    name          = "Authentik"
    client_id     = data.vault_kv_secret_v2.grafana_oidc.data["client_id"]
    client_secret = data.vault_kv_secret_v2.grafana_oidc.data["client_secret"]
    auth_url      = "${var.authentik_url}/application/o/authorize/"
    token_url     = "${var.authentik_url}/application/o/token/"
    api_url       = "${var.authentik_url}/application/o/userinfo/"
    scopes        = "openid email profile"
    # Domain Admins → GrafanaAdmin (server admin); everyone else → Viewer (org-wide,
    # no folder restrictions — folder/team RBAC needs Grafana Enterprise; tracked in #73).
    # allow_assign_grafana_admin MUST be true for the GrafanaAdmin branch to take effect;
    # without it Grafana silently caps OAuth-assigned roles at org Admin and ignores the
    # GrafanaAdmin role string.
    role_attribute_path        = "contains(groups[*], 'Domain Admins') && 'GrafanaAdmin' || 'Viewer'"
    groups_attribute_path      = "groups"
    allow_assign_grafana_admin = true
    allow_sign_up              = true
    use_pkce                   = true
    use_refresh_token          = true
  }
}
