# Collaborator tenants — which apps an external collaborator may reach (ADR 0013 §4,
# "group/claim→tenant").
#
# External partners onboard through the shared collaborator enrollment flow
# (collaborator_enrollment.tf): a per-org reusable invite in collaborator_invites.tf
# (or a one-off minted in the UI) stamps
#
#     attributes.tenant = <key of local.collaborator_tenants below>
#     attributes.org    = <partner org id>
#
# onto an Authentik-LOCAL `external` user with NO AD groups. ADR 0013 §4 says such an
# account reaches exactly the app(s) it was granted and nothing else. Two halves
# enforce that:
#   - GRANT: each tenant below gets an expression policy (`tenant == "<key>"`) bound
#     to each of its apps, OR-ed with the app's AD-group gate in app_access.tf
#     (policy_engine_mode "any"), so access = AD members OR that tenant's collaborators.
#   - DENY everything else: every app with no other gate gets the members-only policy
#     (local.members_only_apps), so a collaborator can't wander into an app that would
#     otherwise be open to "any authenticated user".
#
# WHY attribute-driven and not per-org Authentik groups: the apps key tenants on the
# stable OIDC `sub` in THEIR OWN DB (FishSense: sub_mode = "hashed_user_id"), or on a
# group-name attribute (Label Studio). Authentik only authenticates the partner and
# says which tenant/org they belong to, which scales to many partner orgs with no
# per-org object churning through this repo. (ADR 0013 §5's local-group exception
# deliberately NOT used here.)

locals {
  # tenant (slug; the invite's `tenant`) → what its collaborators may reach.
  #   apps                — app keys of local.app_access_uuids (app_access.tf); one
  #                         grant binding per entry. Drop one to stop exposing that
  #                         app to the tenant.
  #   label_studio_group  — synthetic SAML `Groups` value emitted for the tenant's
  #                         collaborators (label_studio.tf), mapped to a workspace in
  #                         Label Studio's UI. null = tenant doesn't use Label Studio.
  #                         RESERVED: never create an AD group with this name
  #                         (spec/krg-ad/groups.yml) — label_studio.tf strips it from
  #                         the AD-group side so AD membership can't grant it.
  # Plain data on purpose (keys, not UUIDs): label_studio.tf reads this map into the
  # Label Studio provider, so referencing that app's UUID here would be a cycle.
  collaborator_tenants = {
    fishsense = {
      # mobile: partners sign in on the phone too
      apps               = ["fishsense_analytics", "fishsense_oauth", "fishsense_mobile"]
      label_studio_group = null
    }
    # Frog ID partners (e.g. the Australian Museum) annotate in the shared Label
    # Studio Enterprise org (label_studio.tf).
    frog-id = {
      apps               = ["label_studio"]
      label_studio_group = "Frog ID Label Studio Collaborators"
    }
  }

  collaborator_tenant_bindings = merge([
    for tenant, t in local.collaborator_tenants : {
      for app in t.apps : "${tenant}:${app}" => { tenant = tenant, target = local.app_access_uuids[app] }
    }
  ]...)

  # Every application NOT gated by app_access.tf, proxmox_ldap.tf or a tenant grant
  # above. Without a binding Authentik lets ANY authenticated user in — including
  # external collaborators. When you add an app, put it in exactly one of those
  # places or here.
  members_only_apps = {
    outline           = authentik_application.outline.uuid
    mlflow            = authentik_application.mlflow.uuid
    vaultwarden       = authentik_application.vaultwarden.uuid
    guacamole_gate    = authentik_application.guacamole_gate.uuid
    temporal          = authentik_application.temporal.uuid
    e4e_roster        = authentik_application.e4e_roster.uuid
    reference_manager = authentik_application.reference_manager.uuid
  }
}

# ── Grant: one policy per tenant, bound to each of its apps ───────────────────
# Pins the EXACT tenant — never "any non-empty tenant" — so a collaborator minted
# for one tenant can't reach another tenant's apps.
resource "authentik_policy_expression" "collaborator_tenant" {
  for_each   = local.collaborator_tenants
  name       = "${each.key} — collaborator tenant access"
  expression = <<-EOT
    return request.user.attributes.get("tenant") == "${each.key}"
  EOT
}

resource "authentik_policy_binding" "collaborator_tenant" {
  for_each = local.collaborator_tenant_bindings
  target   = each.value.target
  policy   = authentik_policy_expression.collaborator_tenant[each.value.tenant].id
  # order relative to the app_access.tf group bindings is irrelevant under
  # policy_engine_mode "any" (any pass → allow); 10 keeps it after them.
  order = 10
}

# ── Deny: members only on every otherwise-ungated app ─────────────────────────
# Fails OPEN for members on purpose: it denies only a user whose type is literally
# "external" (what collaborator_enrollment.tf's user_write creates). AD-synced users
# are `internal`, and service accounts are `service_account`, so both pass. If the
# comparison ever stopped matching, collaborators would get today's access back —
# nobody in the lab would be locked out of Outline/Vaultwarden.
resource "authentik_policy_expression" "members_only" {
  name       = "Members only — deny external collaborators"
  expression = <<-EOT
    return request.user.type != "external"
  EOT
}

resource "authentik_policy_binding" "members_only" {
  for_each = local.members_only_apps
  target   = each.value
  policy   = authentik_policy_expression.members_only.id
  order    = 0
}

# The FishSense grant used to be one un-keyed policy + a binding map; keep its live
# objects instead of destroy/create (a brief window where partners are locked out).
moved {
  from = authentik_policy_expression.fishsense_collaborator
  to   = authentik_policy_expression.collaborator_tenant["fishsense"]
}
moved {
  from = authentik_policy_binding.fishsense_collaborator["analytics"]
  to   = authentik_policy_binding.collaborator_tenant["fishsense:fishsense_analytics"]
}
moved {
  from = authentik_policy_binding.fishsense_collaborator["oauth"]
  to   = authentik_policy_binding.collaborator_tenant["fishsense:fishsense_oauth"]
}
moved {
  from = authentik_policy_binding.fishsense_collaborator["mobile"]
  to   = authentik_policy_binding.collaborator_tenant["fishsense:fishsense_mobile"]
}

# ── OIDC claim: org / tenant ──────────────────────────────────────────────────
# Emits the collaborator's tenant + org onto the token, so an OIDC app (FishSense)
# can bootstrap its sub→org row on first login. Only present when the client
# REQUESTS the `org` scope (same request-to-receive contract as the `groups` scope in
# applications_e4e.tf). Values are null for a normal AD member (no such attributes),
# which is fine — FishSense treats a member as its own tenant. Resource name kept
# from when this lived in fishsense_collaborators.tf.
resource "authentik_property_mapping_provider_scope" "fishsense_org" {
  name        = "OIDC Scope — org (FishSense tenant)"
  scope_name  = "org"
  description = "Collaborator's tenant/org attributes; consumed by FishSense to key its own per-org isolation on the stable sub."
  expression  = <<-EOT
    return {
      "tenant": request.user.attributes.get("tenant"),
      "org": request.user.attributes.get("org"),
    }
  EOT
}
