# UCSD-compliant password-strength policy — the Authentik half of the password
# mandate (ADR 0010 §4). The AD half (length 12 + complexity + no-expiry) lives
# in spec/krg-ad/password-policy.yml and is enforced by Samba on the unicodePwd
# write-back. The Authentik side adds what AD CANNOT express and covers the paths
# AD doesn't:
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
#
# Enforced on BOTH managed password-set paths, each via the policy below bound to
# that flow's prompt stage:
#   * recovery flow ("Forgot password?")           -> authentik_policy_password.ucsd
#   * in-session change (Settings -> change pwd)    -> authentik_policy_password.default_password_change
# Two policy objects (not one) so the recovery policy stays a clean create while
# the change-password one ADOPTS the stock policy already wired into that flow —
# see its comment. The shared standard lives in the local below so they can't drift.

locals {
  # The UCSD AD password standard, mirrored into Authentik. Keep aligned with
  # spec/krg-ad/password-policy.yml (the AD half).
  ucsd_password = {
    check_static_rules      = true # evaluate length_min (amount_* stay 0 — AD owns complexity)
    length_min              = 12   # UCSD: at least 12
    check_have_i_been_pwned = true # breach screening — the gap AD can't fill
    hibp_allowed_count      = 0    # reject any password seen in a breach
    check_zxcvbn            = true
    zxcvbn_score_threshold  = 3 # 0–4; 3 = "safely unguessable", passphrase-friendly
    error_message           = "Password must be at least 12 characters, not a common/breached password, and not a single dictionary word. A passphrase is easiest."
  }
}

# Recovery flow ("Forgot password?"). Clean create — bound in recovery.tf. Needs
# no import, so it works in CD with no operator step.
resource "authentik_policy_password" "ucsd" {
  name           = "UCSD password standard"
  password_field = "password"

  check_static_rules      = local.ucsd_password.check_static_rules
  length_min              = local.ucsd_password.length_min
  check_have_i_been_pwned = local.ucsd_password.check_have_i_been_pwned
  hibp_allowed_count      = local.ucsd_password.hibp_allowed_count
  check_zxcvbn            = local.ucsd_password.check_zxcvbn
  zxcvbn_score_threshold  = local.ucsd_password.zxcvbn_score_threshold
  error_message           = local.ucsd_password.error_message
}

# In-session change (Settings → change password — the stock default-password-change
# flow, the path that surfaced the original break). That flow's prompt stage
# already binds a stock policy ("default-password-change-password-policy"), shipped
# WEAK: length 8 / zxcvbn 2 / no breach check. Rather than import the prompt stage
# and re-point its binding, we ADOPT that existing policy object and tighten it to
# the UCSD standard — the prompt-stage binding (by pk) is left untouched, so this
# alone covers the dialog.
#
# IMPORTED, not created (brand.tf precedent). Captured read-only from a blueprint
# export 2026-06-18 (pk 63abaf9f-0252-4887-9f42-97a89a2c5164). Only the fields in
# local.ucsd_password change from live (length_min 8→12, check_have_i_been_pwned
# false→true, zxcvbn_score_threshold 2→3, error_message); name + password_field +
# amount_* + symbol_charset are pinned to the live values so nothing else drifts.
# If `tofu plan` proposes changing anything ELSE, re-capture before applying.
#
# One-time import (existing object — without it, apply creates a DUPLICATE policy
# that is NOT bound to the stage, leaving the dialog at length 8):
#   tofu import authentik_policy_password.default_password_change 63abaf9f-0252-4887-9f42-97a89a2c5164
resource "authentik_policy_password" "default_password_change" {
  name           = "default-password-change-password-policy" # pinned to live (no rename)
  password_field = "password"

  # tightened to the UCSD standard
  check_static_rules      = local.ucsd_password.check_static_rules
  length_min              = local.ucsd_password.length_min
  check_have_i_been_pwned = local.ucsd_password.check_have_i_been_pwned
  hibp_allowed_count      = local.ucsd_password.hibp_allowed_count
  check_zxcvbn            = local.ucsd_password.check_zxcvbn
  zxcvbn_score_threshold  = local.ucsd_password.zxcvbn_score_threshold
  error_message           = local.ucsd_password.error_message

  # pinned to live so the import changes nothing unintended
  amount_digits    = 0
  amount_uppercase = 0
  amount_lowercase = 0
  amount_symbols   = 0
  symbol_charset   = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ "
}

# ── Coverage summary ───────────────────────────────────────────────────────────
# recovery flow            : authentik_policy_password.ucsd, bound in recovery.tf.
# default-password-change  : authentik_policy_password.default_password_change,
#                            already bound by the stock prompt stage (pk by value).
# No remaining unmanaged password-set flow (no self-enrollment — users come from
# AD). Both paths now enforce length 12 + breach + zxcvbn; AD continues to enforce
# complexity on the write-back for AD users.
