# How long a user stays signed into Authentik (the SSO session) — distinct from the
# per-app OIDC token validity in applications_*.tf (access_token_validity /
# refresh_token_validity), which only governs a downstream app's token, not whether
# you have to re-enter your KRG.LOCAL password.
#
# The SSO session lifetime is the `session_duration` on the user_login stage of the
# DEFAULT authentication flow (brand.tf's flow_authentication,
# fed7617e-bad3-48ca-ad83-a8cda150b646). Authentik ships that stage
# (`default-authentication-login`) with session_duration = "seconds=0", which means
# the session ends when the browser is closed — that's why users get logged out.
#
# We bring that pre-existing stage under management the SAME way brand.tf brought the
# default identification stage under management: a one-time `tofu import` of the live
# object, changing ONLY the two session fields below. Everything else must match live
# state exactly so the import doesn't clobber anything.
#
# Policy (chosen 2026-07-10): a short 12-hour base session, but a "Remember me on this
# device" checkbox (surfaced by a non-zero remember_me_offset) that extends an opted-in
# session to ~30 days. Users who don't tick it re-auth daily; users who do stay signed
# in for a month.
#
# DISCOVERY REQUIRED BEFORE APPLYING (IaC-strict: capture read-only, then encode):
#   1. Get the stage pk + its live field values:
#        GET /api/v3/stages/user/login/?name=default-authentication-login
#   2. Confirm the four "matches live" fields below equal the live values (Authentik's
#      defaults are encoded here; verify they weren't changed in the UI). If `tofu plan`
#      proposes changing anything OTHER than session_duration / remember_me_offset after
#      import, STOP and re-capture — do not accept the diff.
#   3. Adoption is now DECLARATIVE — the `import` block at the bottom of this file
#      adopts the built-in stage on first apply (pk resolved by the data source), so
#      no manual `tofu import` is needed. If plan still shows a CREATE, the data
#      source didn't find the stage — re-check the name.
#
# The existing flow_stage_binding that puts this stage in the login flow is left
# UNMANAGED (same as brand.tf leaves the identification stage's binding unmanaged) —
# we only need to edit the stage's fields, not rewire the flow.

# Resolve the built-in stage's pk by name so the import block below can adopt it
# without a hand-copied UUID (the pk is generated per-install).
data "authentik_stage" "default_authentication" {
  name = "default-authentication-login"
}

resource "authentik_stage_user_login" "default_authentication" {
  name = "default-authentication-login"

  # The two intentional changes (were "seconds=0" / "seconds=0"):
  session_duration   = "hours=12" # base session for users who don't opt in
  remember_me_offset = "days=30"  # adds a "Remember me" checkbox; opted-in sessions last ~30d

  # Below must match live state exactly (Authentik defaults — verify in discovery step 2):
  terminate_other_sessions = false
  network_binding          = "no_binding"
  geoip_binding            = "no_binding"
}

# ADOPT the built-in stage instead of CREATE-ing it — it always pre-exists, so a
# plain apply 400s "stage with this name already exists" (deploy 29316839210).
# The import block makes the first apply IMPORT-then-update; the data source
# supplies its pk at plan time so nothing is hand-copied. Idempotent: once the
# resource is in state the block is a no-op. This is the declarative form of the
# one-time `tofu import` the header used to require (now removed from the runbook).
import {
  to = authentik_stage_user_login.default_authentication
  id = data.authentik_stage.default_authentication.id
}
