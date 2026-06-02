# Synology DSM provider — talks to e4e-nas over the DSM Web API.
#
# Credentials come from variables (terraform.tfvars, gitignored) or TF_VAR_*.
# Use a dedicated admin-group API account, NOT the built-in `admin` (which the
# runbook tells you to disable). See docs/e4e-nas-dsm.md.
provider "synology" {
  host     = var.dsm_host
  user     = var.dsm_user
  password = var.dsm_password

  # Leave blank unless the API account has TOTP 2FA (then set the shared
  # secret, not a one-time code). Empty string = no 2FA.
  otp_secret = var.dsm_otp_secret

  # NOTE: DSM ships a self-signed cert. If `tofu plan` fails on cert
  # verification, either install a trusted cert on the NAS or check the
  # provider docs for its insecure/skip-verify option and add it here.
}
