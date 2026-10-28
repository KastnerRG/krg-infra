# Passwordless passkey (WebAuthn) login.
#
# Lets users register a passkey (platform biometric — Touch ID / Face ID / Windows
# Hello — or a cross-platform security key / phone) and then sign in with JUST the
# passkey, no KRG.LOCAL password. The password path (LDAP source, ldap.tf) stays; the
# passkey is an additional "Use a passkey" button on the same login screen.
#
# Three parts:
#   1. Enrollment  — a WebAuthn setup stage bound into the user-settings flow, so users
#      self-register a passkey from Account -> Settings. It forces DISCOVERABLE (resident)
#      credentials so they can be used in the passwordless flow.
#   2. Passwordless flow — what the "Use a passkey" button launches. No identification
#      stage: the WebAuthn validation runs in discoverable mode (the resident key both
#      identifies AND authenticates), then a user-login stage opens the session.
#   3. Login-screen wiring — the "Use a passkey" button is the passwordless_flow
#      attribute of the default-authentication-identification stage. That stage is
#      ALREADY managed in brand.tf (it was imported there to wire recovery_flow), so
#      the button is turned on by one line over there — NOT by importing the stage
#      again here (two resources can't manage one object). See brand.tf.
#
# Pattern mirrors recovery.tf (custom flow = flow + stages + flow_stage_bindings).
# Bindings target authentik_flow.*.uuid, never .id — .id is the slug, which the
# bindings API rejects (same lesson recovery.tf documents).

# --- 1. Enrollment -----------------------------------------------------------------

resource "authentik_stage_authenticator_webauthn" "passkey_enroll" {
  name          = "krg-passkey-enroll"
  friendly_name = "Passkey"
  # MUST be a discoverable (resident) credential, otherwise the passwordless flow has
  # no username to look the key up by and the "Use a passkey" button finds nothing.
  resident_key_requirement = "required"
  # "preferred" avoids locking out authenticators that can't do user-verification.
  # For true passwordless, "required" is stronger (a stolen security key alone can't
  # log in) — flip both this and webauthn_user_verification below to tighten.
  user_verification = "preferred"
  # authenticator_attachment left unset → allow BOTH platform authenticators and
  # cross-platform security keys / phones.
}

# Read-only lookup — adding a binding to this flow is additive and does not require
# Terraform to manage the flow itself.
data "authentik_flow" "user_settings" {
  slug = "default-user-settings-flow"
}

resource "authentik_flow_stage_binding" "passkey_enroll_user_settings" {
  # Data source exports its pk as `.id` (unlike the authentik_flow RESOURCE, whose
  # `.id` is the slug and needs `.uuid` — see the bindings in recovery.tf).
  target = data.authentik_flow.user_settings.id
  stage  = authentik_stage_authenticator_webauthn.passkey_enroll.id
  order  = 30
}

# --- 2. Passwordless login flow ----------------------------------------------------

resource "authentik_flow" "passwordless" {
  name        = "Passwordless passkey login"
  title       = "Sign in with a passkey"
  slug        = "krg-passwordless-authentication"
  designation = "authentication"
  # You must be logged out to start it (it's the login path).
  authentication = "require_unauthenticated"
}

resource "authentik_stage_authenticator_validate" "passwordless" {
  name           = "krg-passkey-validate"
  device_classes = ["webauthn"]
  # No user is pending when launched from the passwordless button, so there is nothing
  # to "configure"; deny anything that isn't a usable webauthn credential.
  not_configured_action = "deny"
  # See the user_verification note on the enroll stage above re: "preferred" vs "required".
  webauthn_user_verification = "preferred"
}

resource "authentik_stage_user_login" "passwordless" {
  name = "krg-passwordless-login"

  # Session parity with the password path (session.tf's default-authentication-login):
  # a 12h base session plus a "Stay signed in?" checkbox extending an opted-in session
  # to ~30 days. Without these the provider defaults to session_duration = "seconds=0"
  # (session dies when the browser closes) AND remember_me_offset = "seconds=0" (no
  # checkbox at all), so a security-key login was strictly worse than a password login.
  # This resource is fully ours (built by this file), so no import is needed — unlike
  # the built-in default-authentication-login stage session.tf had to adopt.
  session_duration   = "hours=12"
  remember_me_offset = "days=30"
}

resource "authentik_flow_stage_binding" "passwordless_validate" {
  target = authentik_flow.passwordless.uuid
  stage  = authentik_stage_authenticator_validate.passwordless.id
  order  = 10
}

resource "authentik_flow_stage_binding" "passwordless_login" {
  target = authentik_flow.passwordless.uuid
  stage  = authentik_stage_user_login.passwordless.id
  order  = 20
}

# --- 3. Login-screen wiring --------------------------------------------------------
#
# The "Use a passkey" button is turned on in brand.tf, by setting passwordless_flow
# on authentik_stage_identification.default_authentication (the auto-created
# default-authentication-identification stage that every login screen runs — already
# under management there for recovery_flow). Nothing to do here; this comment marks
# where that wiring lives.
