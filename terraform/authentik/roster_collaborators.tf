# Roster's tenant/org picker. Authentik has no native partner-org directory:
# publish the existing tenant configuration as brand metadata rather than asking
# roster to infer authorization from user attributes or reusable bearer invites.
locals {
  roster_collaborator_partners = merge(
    { for org, invite in local.collaborator_invites : org => invite.tenant },
    { australian-museum = "frog-id" },
  )
  # Direct web destinations; the mobile provider's blank://blank launch URI is
  # intentionally excluded. App access still comes from collaborator_tenants.tf.
  roster_collaborator_links = {
    fishsense = [
      { name = authentik_application.fishsense_oauth.name, url = authentik_application.fishsense_oauth.meta_launch_url },
      { name = authentik_application.fishsense_analytics.name, url = authentik_application.fishsense_analytics.meta_launch_url },
    ]
    frog-id = [
      # The Authentik tile uses IdP-initiated SAML. The direct destination is
      # Heartex; users may need to select their company's SSO on its login page.
      { name = authentik_application.label_studio.name, url = "https://app.heartex.com/" },
    ]
  }
  roster_collaborator_catalog = {
    flow     = authentik_flow.collaborator_enrollment.uuid
    flowSlug = authentik_flow.collaborator_enrollment.slug
    tenants = [for tenant in sort(keys(local.collaborator_tenants)) : {
      id   = tenant
      name = tenant
      organizations = [for org, org_tenant in local.roster_collaborator_partners : {
        id = org, name = org
      } if org_tenant == tenant]
      applications = local.roster_collaborator_links[tenant]
    }]
  }
}

# Dedicated API principal. This is separate from roster OIDC login and has no AD
# identity, groups, or superuser permission. Do not reuse the deploy admin token.
resource "authentik_rbac_role" "roster_invitations" {
  name = "Roster collaborator invitation API"
}

resource "authentik_user" "roster_invitations" {
  username = "svc-roster-invitations"
  name     = "Roster collaborator invitation API"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  roles    = [authentik_rbac_role.roster_invitations.id]
}

resource "authentik_rbac_permission_role" "roster_add_invitation" {
  role       = authentik_rbac_role.roster_invitations.id
  permission = "authentik_stages_invitation.add_invitation"
}

resource "authentik_rbac_permission_role" "roster_view_brand" {
  role       = authentik_rbac_role.roster_invitations.id
  model      = "authentik_brands.brand"
  permission = "view_brand"
  object_id  = authentik_brand.default.id
}

resource "authentik_rbac_permission_role" "roster_view_enrollment" {
  role       = authentik_rbac_role.roster_invitations.id
  model      = "authentik_flows.flow"
  permission = "view_flow"
  object_id  = authentik_flow.collaborator_enrollment.uuid
}

resource "authentik_token" "roster_invitations" {
  identifier   = "roster-collaborator-invitations-api"
  user         = authentik_user.roster_invitations.id
  intent       = "api"
  expiring     = false
  retrieve_key = true
  description  = "Backend-only roster single-use collaborator invitations"
}

# Seed before adding this path to the shared runtime secret renderer. The
# krg-prod/authentik-managed writer/read policies already cover the path.
resource "vault_kv_secret_v2" "roster_invitations" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/roster-invitations"
  data_json = jsonencode({
    url      = var.authentik_url
    brand_id = authentik_brand.default.id
    token    = authentik_token.roster_invitations.key
  })
  depends_on = [
    authentik_rbac_permission_role.roster_add_invitation,
    authentik_rbac_permission_role.roster_view_brand,
    authentik_rbac_permission_role.roster_view_enrollment,
  ]
}
