# UCSD-compliant password-strength policy — the Authentik half of the password
# mandate (ADR 0010 §4). The AD half (length 12 + complexity + no-expiry) lives
# in spec/krg-ad/password-policy.yml and is enforced by Samba on the unicodePwd
# write-back. This policy adds what AD CANNOT express and covers the paths AD
# doesn't:
#
#   * Breach screening — reject passwords seen in a known breach (HaveIBeenPwned).
#   * Strength / "not a recognizable word" — zxcvbn rejects single dictionary
#     words and weak patterns; passphrases (UCSD-preferred) score well and pass.
#   * Length, in-form — a clear "too short" message at submit time instead of the
#     opaque AD-write failure an under-12 password would otherwise hit.
#   * Local (non-AD) Authentik accounts — they have no AD write-back, so this is
#     the ONLY length/strength enforcement they get.
#
# DELIBERATELY NOT character-class rules (amount_uppercase/…): AD already owns the
# "≥3 of 4 categories + not-username" complexity check on the write-back. Forcing
# all four categories here would reject AD-valid passwords at the form — a mismatch
# between the two layers. Length + breach + zxcvbn is the complementary set, and
# matches UCSD's "length is more secure than complexity" guidance.

resource "authentik_policy_password" "ucsd" {
  name = "UCSD password standard"

  # Field key of the password prompt this policy validates. Authentik's default
  # is "password"; the recovery flow's prompt uses the same key (recovery.tf).
  password_field = "password"

  # Length floor — mirrors the AD min-pwd-length (spec/krg-ad/password-policy.yml).
  # check_static_rules must stay on for length_min to be evaluated; amount_* are
  # left at 0 on purpose (see header — AD owns complexity).
  check_static_rules = true
  length_min         = 12

  # Breach screening — the gap AD can't fill. Reject any password found in a
  # public breach corpus (count > 0).
  check_have_i_been_pwned = true
  hibp_allowed_count      = 0

  # Strength / dictionary — rejects single recognizable words and weak patterns.
  # Score is 0–4; 3 ("safely unguessable") is strong but passphrase-friendly.
  # Tune here if it proves too strict in practice.
  check_zxcvbn           = true
  zxcvbn_score_threshold = 3

  error_message = "Password must be at least 12 characters, not a common/breached password, and not a single dictionary word. A passphrase is easiest."
}

# ── Where this policy is enforced ──────────────────────────────────────────────
#
# A password policy only takes effect when bound as a validation policy on each
# prompt stage that SETS a password. Bound on the managed self-service recovery
# flow's prompt stage (authentik_stage_prompt.recovery, recovery.tf), alongside
# the existing passwords-must-match policy.
#
# STILL UNBOUND (follow-up): the stock in-session `default-password-change` flow
# (the one a logged-in user hits from Settings — it surfaced the original break)
# isn't Terraform-managed yet, so this policy can't attach to it from here.
# Binding it needs a one-time flow/stage import (same pattern as the brand object
# noted in recovery.tf), then appending authentik_policy_password.ucsd.id to that
# stage's validation_policies. Until then, default-password-change relies on AD's
# write-back enforcement for length/complexity (fail-closed) but gets no
# breach/zxcvbn screening, and local (non-AD) accounts get nothing there.
