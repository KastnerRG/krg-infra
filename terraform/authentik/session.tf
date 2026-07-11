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
#   3. One-time import (already-existing object, not a create):
#        tofu import authentik_stage_user_login.default_authentication <pk>
#
# The existing flow_stage_binding that puts this stage in the login flow is left
# UNMANAGED (same as brand.tf leaves the identification stage's binding unmanaged) —
# we only need to edit the stage's fields, not rewire the flow.

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
