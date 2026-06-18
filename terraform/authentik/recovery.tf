# Self-service password recovery ("Forgot password?") flow.
#
# Authentik federates users from Samba AD via the LDAP source (ldap.tf,
# sync_users_password = true): when a user's password is set through Authentik, the
# LDAP source writes it back to AD. So this flow isn't just an Authentik-local
# credential reset — it's the self-service path for a user's actual KRG.LOCAL domain
# password, for every app behind SSO at once.
#
# Stage chain: identify by email/username -> email a one-time recovery link -> prompt
# for a new password (validated to match its confirmation) -> write it to the user
# (triggering the LDAP writeback).
#
# Email delivery uses use_global_settings = true on the email stage, so it inherits
# AUTHENTIK_EMAIL__* from the authentik_worker compose environment (host/from/auth) —
# no SMTP credentials are duplicated into Terraform state.
#
# NOT YET WIRED to the default brand's "Forgot password?" link — that touches a brand
# object Authentik auto-created on first boot (fleet-wide blast radius: every app's
# login page reads it). See the comment in brand.tf for the one-time import + apply.

resource "authentik_flow" "recovery" {
  name        = "Password recovery"
  title       = "Reset your KRG password"
  slug        = "default-recovery-flow"
  designation = "recovery"
  # Anonymous users must be able to START this flow (that's the point of "forgot
  # password") — the identification stage below is what actually verifies them.
  authentication = "none"
}

resource "authentik_stage_identification" "recovery" {
  name                      = "Recovery — identify"
  user_fields               = ["email", "username"]
  case_insensitive_matching = true
  # Don't reveal whether a given email/username actually has an account —
  # avoids account enumeration via the recovery form.
  show_matched_user   = false
  pretend_user_exists = true
}

resource "authentik_stage_email" "recovery" {
  name                = "Recovery — send email"
  use_global_settings = true
  subject             = "KRG password reset"
  template            = "email/password_reset.html"
  token_expiry        = "minutes=30"
}

# Same validation Authentik's own "create recovery flow" wizard generates — checks the
# two prompt fields below match before letting the flow continue to user-write.
resource "authentik_policy_expression" "recovery_password_match" {
  name       = "Recovery — passwords must match"
  expression = <<-EOT
    password = request.context.get("prompt_data", {}).get("password")
    password_repeat = request.context.get("prompt_data", {}).get("password_repeat")
    if password != password_repeat:
        ak_message("Passwords don't match.")
        return False
    return True
  EOT
}

resource "authentik_stage_prompt_field" "recovery_password" {
  name      = "recovery-password"
  field_key = "password"
  label     = "New password"
  type      = "password"
  required  = true
  order     = 0
}

resource "authentik_stage_prompt_field" "recovery_password_repeat" {
  name      = "recovery-password-repeat"
  field_key = "password_repeat"
  label     = "Confirm new password"
  type      = "password"
  required  = true
  order     = 1
}

resource "authentik_stage_prompt" "recovery" {
  name = "Recovery — set new password"
  fields = [
    authentik_stage_prompt_field.recovery_password.id,
    authentik_stage_prompt_field.recovery_password_repeat.id,
  ]
  # Two validation policies run on submit: the new password must (1) match its
  # confirmation and (2) meet the UCSD strength standard (length + breach +
  # zxcvbn — password_policy.tf, ADR 0010 §4).
  validation_policies = [
    authentik_policy_expression.recovery_password_match.id,
    authentik_policy_password.ucsd.id,
  ]
}

resource "authentik_stage_user_write" "recovery" {
  name = "Recovery — write new password"
  # Recovery is for EXISTING users only — never create an account from this flow.
  user_creation_mode = "never_create"
}

resource "authentik_flow_stage_binding" "recovery_identification" {
  # authentik_flow's `id` is its SLUG ("default-recovery-flow"), not a UUID — the
  # bindings API rejects that. `uuid` is the actual pk this endpoint needs.
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_identification.recovery.id
  order  = 10
}

resource "authentik_flow_stage_binding" "recovery_email" {
  # authentik_flow's `id` is its SLUG ("default-recovery-flow"), not a UUID — the
  # bindings API rejects that. `uuid` is the actual pk this endpoint needs.
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_email.recovery.id
  order  = 20
}

resource "authentik_flow_stage_binding" "recovery_prompt" {
  # authentik_flow's `id` is its SLUG ("default-recovery-flow"), not a UUID — the
  # bindings API rejects that. `uuid` is the actual pk this endpoint needs.
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_prompt.recovery.id
  order  = 30
}

resource "authentik_flow_stage_binding" "recovery_user_write" {
  # authentik_flow's `id` is its SLUG ("default-recovery-flow"), not a UUID — the
  # bindings API rejects that. `uuid` is the actual pk this endpoint needs.
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_user_write.recovery.id
  order  = 40
}
