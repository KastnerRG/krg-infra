# Frog ID collaborator access to Label Studio (ADR 0013 §4, "group/claim→tenant").
#
# Frog ID is an E4E project that labels in the shared Label Studio Enterprise org
# (label_studio.tf). Its EXTERNAL partner orgs (e.g. the Australian Museum) onboard
# through the same shared collaborator enrollment flow FishSense uses: a reusable
# per-org invite in collaborator_invites.tf with tenant = "frog-id" stamps
#
#     attributes.tenant = "frog-id", attributes.org = "<org-id>"
#
# onto each self-served local account. This file turns that attribute into
# (a) the launch gate for the Label Studio app — its AD-group bindings in
# app_access.tf would otherwise lock non-AD collaborators out — and (b) a synthetic
# Groups value in the SAML assertion (label_studio.tf) so Label Studio can map
# collaborators to the Frog ID workspace instead of its default role.

# Same shape as fishsense_collaborator: pin the exact tenant, never "any non-empty
# tenant", so a collaborator minted for FishSense can't reach Label Studio.
resource "authentik_policy_expression" "frog_id_collaborator" {
  name       = "Frog ID — collaborator tenant access"
  expression = <<-EOT
    return request.user.attributes.get("tenant") == "frog-id"
  EOT
}

# OR-ed with the app_access.tf group bindings (policy_engine_mode "any"), so access
# = Label Studio AD-group members OR frog-id collaborators.
resource "authentik_policy_binding" "frog_id_collaborator_label_studio" {
  target = authentik_application.label_studio.uuid
  policy = authentik_policy_expression.frog_id_collaborator.id
  order  = 10
}
