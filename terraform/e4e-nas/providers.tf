# Synology DSM provider — talks to e4e-nas over the DSM Web API.
#
# Credentials come from variables (terraform.tfvars, gitignored) or TF_VAR_*.
# Use a dedicated admin-group API account, NOT the built-in `admin` (which the
# runbook tells you to disable). See docs/e4e-nas-dsm.md.
provider "synology" {
  host     = var.dsm_host
  user     = var.dsm_user
  password = var.dsm_password

  # Set ONLY when the API account has TOTP 2FA. The value is the base32
  # shared secret (NOT a 6-digit code, NOT the otpauth:// URI). The provider
  # validates length 16-32 even on empty strings, so we pass null when unset.
  otp_secret = var.dsm_otp_secret != null && var.dsm_otp_secret != "" ? var.dsm_otp_secret : null

  # NOTE: DSM ships a self-signed cert. If `tofu plan` fails on cert
  # verification, either install a trusted cert on the NAS or check the
  # provider docs for its insecure/skip-verify option and add it here.
}
