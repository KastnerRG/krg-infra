# The default brand controls fleet-wide login-page chrome (incl. the "Forgot
# password?" link). It was auto-created by Authentik on first boot and brought
# under Terraform management here via `tofu import` so we can point flow_recovery
# at authentik_flow.recovery (recovery.tf) without recreating/duplicating it.
#
# Values below were captured read-only from the live object on 2026-06-17
# (GET /api/v3/core/brands/, brand_uuid e5eb853f-fcfb-4d06-b364-1556759db0af)
# before this resource existed in Terraform, specifically so the import doesn't
# clobber anything — flow_recovery is the ONLY field changing from its live value
# (null -> the new recovery flow's uuid). If you ever see `tofu plan` proposing to
# change anything ELSE on this resource, treat it as a sign this block has drifted
# from live state — re-capture before applying, don't just accept the diff.
#
# One-time import (already-existing object, not a new create):
#   tofu import authentik_brand.default e5eb853f-fcfb-4d06-b364-1556759db0af

resource "authentik_brand" "default" {
  domain  = "authentik-default"
  default = true

  branding_title                    = "authentik"
  branding_logo                     = "/static/dist/assets/icons/icon_left_brand.svg"
  branding_favicon                  = "/static/dist/assets/icons/icon.png"
  branding_default_flow_background  = "/static/dist/assets/images/flow_background.jpg"

  flow_authentication = "fed7617e-bad3-48ca-ad83-a8cda150b646"
  flow_invalidation    = "01062aa2-97b3-4392-8487-7f89ce7955ba"
  flow_user_settings   = "91a3ac41-505a-43be-a99e-e06444fe29cd"

  # The new addition — everything else above matches live state exactly.
  flow_recovery = authentik_flow.recovery.uuid
}
