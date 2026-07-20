# External-collaborator invitation / enrollment flow (ADR 0013 §4).
#
# The onboarding path for someone who needs ONLY web services and is NOT a lab
# member: they do NOT get an AD account (no host/compute/storage reach). They get
# an Authentik-LOCAL account, minted by this flow, authorized explicitly per
# application. Minimal trust by construction — see docs/adr/0013.
#
# Invite-only, no open self-signup: the invitation stage below sets
# `continue_flow_without_invitation = false`, so hitting the flow URL without a
# valid invitation token dead-ends. An admin mints each invite out of band (there
# is NO `authentik_invitation` provider resource — invites are per-collaborator
# and ephemeral, and would drop pre-fill data into tofu state), see README.
#
# Stage chain (bindings below):
#   invitation  -> validate the invite token (deny if absent)
#   prompt      -> collect email / name / username / password (+ hidden tenant/org
#                  carriers pre-filled from the invite's fixed_data)
#   user_write  -> create the account as an INACTIVE `external` user
#   email       -> send a confirmation link; on click, ACTIVATE the account
#                  (activate_user_on_success) — the email-verification step
#   user_login  -> open the session
#
# Multitenancy (FishSense): the invite's fixed_data carries the tenant/org, which
# the hidden prompt fields persist onto user.attributes (see fishsense_collaborators.tf
# for how that attribute gates the FishSense apps and is emitted as an OIDC claim).
# Authentik stays the IdP; org isolation is enforced app-side, keyed on the stable
# `sub` (the FishSense OIDC providers already use sub_mode = "hashed_user_id").
#
# Pattern mirrors recovery.tf (custom flow = flow + stages + flow_stage_bindings).
# Bindings target authentik_flow.*.uuid, never .id — .id is the slug, which the
# bindings API rejects (the lesson recovery.tf documents).

resource "authentik_flow" "collaborator_enrollment" {
  name        = "Collaborator enrollment"
  title       = "Set up your KRG collaborator account"
  slug        = "krg-collaborator-enrollment"
  designation = "enrollment"
  # You must be logged out to enroll; the invitation token is what actually
  # authorizes starting the flow.
  authentication = "require_unauthenticated"
}

# --- invitation gate ----------------------------------------------------------

resource "authentik_stage_invitation" "collaborator" {
  name = "krg-collaborator-invitation"
  # THE anti-open-signup switch: with this false, the flow refuses to continue
  # unless a valid invitation token is present (?itoken=… on the enrollment link).
  # Do NOT flip this to true — that turns the flow into public self-registration,
  # exactly what ADR 0013 §4 forbids.
  continue_flow_without_invitation = false
}

# --- prompt (account details) -------------------------------------------------

resource "authentik_stage_prompt_field" "collab_email" {
  name      = "krg-collab-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  required  = true
  order     = 0
}

resource "authentik_stage_prompt_field" "collab_name" {
  name      = "krg-collab-name"
  field_key = "name"
  label     = "Full name"
  type      = "text"
  required  = true
  order     = 1
}

resource "authentik_stage_prompt_field" "collab_username" {
  name      = "krg-collab-username"
  field_key = "username"
  label     = "Username"
  type      = "username"
  required  = true
  order     = 2
}

resource "authentik_stage_prompt_field" "collab_password" {
  name      = "krg-collab-password"
  field_key = "password"
  label     = "Password"
  type      = "password"
  required  = true
  order     = 3
}

resource "authentik_stage_prompt_field" "collab_password_repeat" {
  name      = "krg-collab-password-repeat"
  field_key = "password_repeat"
  label     = "Confirm password"
  type      = "password"
  required  = true
  order     = 4
}

# Hidden tenant/org carriers. The `attributes.` prefix is load-bearing: the
# user_write stage persists any prompt_data key named `attributes.<x>` onto
# user.attributes["<x>"]. These fields are pre-filled from the invitation's
# fixed_data (fixed_data key must MATCH the field_key, i.e. the admin sets
# `{"attributes.tenant": "fishsense", "attributes.org": "<org-id>"}` on the
# invite). Not required — a generic (non-tenant) collaborator invite just leaves
# them empty. See README "Minting an invite".
resource "authentik_stage_prompt_field" "collab_tenant" {
  name      = "krg-collab-tenant"
  field_key = "attributes.tenant"
  label     = "Tenant"
  type      = "hidden"
  required  = false
  order     = 5
}

resource "authentik_stage_prompt_field" "collab_org" {
  name      = "krg-collab-org"
  field_key = "attributes.org"
  label     = "Org"
  type      = "hidden"
  required  = false
  order     = 6
}

resource "authentik_stage_prompt" "collaborator_enrollment" {
  name = "krg-collaborator-enrollment-prompt"
  fields = [
    authentik_stage_prompt_field.collab_email.id,
    authentik_stage_prompt_field.collab_name.id,
    authentik_stage_prompt_field.collab_username.id,
    authentik_stage_prompt_field.collab_password.id,
    authentik_stage_prompt_field.collab_password_repeat.id,
    authentik_stage_prompt_field.collab_tenant.id,
    authentik_stage_prompt_field.collab_org.id,
  ]
  # Reuse recovery.tf's two validators — they key on the SAME prompt_data field
  # keys (password / password_repeat):
  #   1. passwords must match, and
  #   2. the UCSD strength/breach standard (password_policy.tf). For a local
  #      (non-AD) collaborator this is the ONLY password gate — there is no AD
  #      write-back to enforce complexity.
  validation_policies = [
    authentik_policy_expression.recovery_password_match.id,
    authentik_policy_password.ucsd.id,
  ]
}

# --- create the account (inactive until email-verified) -----------------------

resource "authentik_stage_user_write" "collaborator_enrollment" {
  name = "krg-collaborator-enrollment-write"
  # Enrollment creates the account (recovery, by contrast, is never_create).
  user_creation_mode = "create_when_required"
  # External = web-only, non-AD, minimal trust (ADR 0013 §4). This is what keeps
  # collaborators out of the AD/member trust tier.
  user_type = "external"
  # Created INACTIVE; the email stage below flips them active only after they
  # click the confirmation link (activate_user_on_success). Belt-and-suspenders
  # on top of the admin-issued invite.
  create_users_as_inactive = true
}

# --- email verification (activates the account) -------------------------------

resource "authentik_stage_email" "collaborator_enrollment" {
  name = "krg-collaborator-enrollment-verify"
  # Inherit AUTHENTIK_EMAIL__* from the authentik_worker compose environment — no
  # SMTP credentials duplicated into tofu state (same as recovery.tf).
  use_global_settings = true
  # THE verification step: on link-click, activate the user written above.
  activate_user_on_success = true
  subject                  = "Confirm your KRG collaborator account"
  # Stock enrollment-confirmation template (ships with Authentik).
  template     = "email/account_confirmation.html"
  token_expiry = "minutes=30"
}

# --- open the session ---------------------------------------------------------

resource "authentik_stage_user_login" "collaborator_enrollment" {
  name = "krg-collaborator-enrollment-login"
  # Session parity with the password path (session.tf): 12h base + a 30d
  # "Stay signed in?" opt-in. Without these the provider defaults to 0 (session
  # dies on browser close, no remember-me checkbox).
  session_duration   = "hours=12"
  remember_me_offset = "days=30"
}

# --- bindings (order matters: write BEFORE verify BEFORE login) ---------------
# target = authentik_flow.*.uuid, never .id (.id is the slug — bindings API 400s).

resource "authentik_flow_stage_binding" "collab_invitation" {
  target = authentik_flow.collaborator_enrollment.uuid
  stage  = authentik_stage_invitation.collaborator.id
  order  = 10
}

resource "authentik_flow_stage_binding" "collab_prompt" {
  target = authentik_flow.collaborator_enrollment.uuid
  stage  = authentik_stage_prompt.collaborator_enrollment.id
  order  = 20
}

resource "authentik_flow_stage_binding" "collab_user_write" {
  target = authentik_flow.collaborator_enrollment.uuid
  stage  = authentik_stage_user_write.collaborator_enrollment.id
  order  = 30
}

resource "authentik_flow_stage_binding" "collab_email" {
  target = authentik_flow.collaborator_enrollment.uuid
  stage  = authentik_stage_email.collaborator_enrollment.id
  order  = 40
}

resource "authentik_flow_stage_binding" "collab_user_login" {
  target = authentik_flow.collaborator_enrollment.uuid
  stage  = authentik_stage_user_login.collaborator_enrollment.id
  order  = 50
}
