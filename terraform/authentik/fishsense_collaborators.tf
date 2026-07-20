# FishSense multitenant collaborator access (ADR 0013 §4, "group/claim→tenant").
#
# FishSense onboards EXTERNAL partners through the shared collaborator enrollment
# flow (collaborator_enrollment.tf). The invite an admin mints carries the tenant
# and the partner org in its fixed_data:
#
#     fixed_data = { "attributes.tenant": "fishsense", "attributes.org": "<org-id>" }
#
# The enrollment flow persists those onto the local user's attributes. This file
# turns that attribute into (a) the access gate for the FishSense apps and (b) an
# OIDC claim FishSense can read.
#
# WHY attribute-driven and not per-org Authentik groups: FishSense keys tenants on
# the stable OIDC `sub` in ITS OWN DB regardless (its providers use
# sub_mode = "hashed_user_id"). Authentik's job is only to authenticate the
# partner and tell FishSense which org they belong to; the actual per-org
# isolation lives in FishSense, which scales to many partner orgs without a
# per-org object churning through this repo. (Confirmed design; ADR 0013 §5's
# local-group exception deliberately NOT used here.)

# ── OIDC claim: org / tenant ──────────────────────────────────────────────────
# Emits the collaborator's tenant + org onto the token, so FishSense can bootstrap
# the sub→org row on first login. Only present when the client REQUESTS the `org`
# scope (same request-to-receive contract as the `groups` scope in
# applications_e4e.tf) — FishSense must add `org` to its OAuth client scopes.
# Values are null for a normal AD member (no such attributes), which is fine —
# FishSense treats a member as its own tenant.
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

# ── Access gate: FishSense-tenant collaborators ───────────────────────────────
# The FishSense apps are ALREADY gated to the "FishSense" AD group (app_access.tf).
# Collaborators are non-AD, so that group binding alone would lock them out. This
# expression policy is a SECOND binding on each FishSense app; because the apps'
# policy_engine_mode defaults to "any" (OR), access is granted to
#   (FishSense AD-group members) OR (tenant == "fishsense" collaborators).
# Do NOT widen this to "any non-empty tenant" — it must pin "fishsense" so a
# collaborator minted for another tenant can't reach the FishSense apps.
resource "authentik_policy_expression" "fishsense_collaborator" {
  name       = "FishSense — collaborator tenant access"
  expression = <<-EOT
    return request.user.attributes.get("tenant") == "fishsense"
  EOT
}

# One binding per FishSense application, OR-ed with the existing AD-group gate.
# To stop exposing a given app to external partners, drop it from this map.
locals {
  fishsense_collab_targets = {
    analytics    = authentik_application.fishsense_analytics.uuid
    oauth        = authentik_application.fishsense_oauth.uuid
    orchestrator = authentik_application.fishsense_orchestrator.uuid
  }
}

resource "authentik_policy_binding" "fishsense_collaborator" {
  for_each = local.fishsense_collab_targets
  target   = each.value
  policy   = authentik_policy_expression.fishsense_collaborator.id
  # order relative to the app_access.tf group bindings is irrelevant under
  # policy_engine_mode "any" (any pass → allow); 10 keeps it after them.
  order = 10
}
