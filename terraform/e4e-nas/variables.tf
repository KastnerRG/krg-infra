# Inputs for the e4e-nas layer. Fill secrets in terraform.tfvars (gitignored)
# or export TF_VAR_<name>. See terraform.tfvars.example.

variable "dsm_host" {
  description = "DSM web URL incl. scheme and port. The prometheus blackbox probe targets :6021, so DSM is assumed there — adjust if it actually serves on 5001."
  type        = string
  default     = "https://e4e-nas.ucsd.edu:6021"
}

variable "dsm_user" {
  description = "DSM account in the administrators group used for the API. NOT the built-in 'admin'."
  type        = string
}

variable "dsm_password" {
  description = "Password for dsm_user. Provide via terraform.tfvars or TF_VAR_dsm_password — never commit it."
  type        = string
  sensitive   = true
}

variable "dsm_otp_secret" {
  description = "TOTP base32 shared secret for dsm_user if 2FA is enabled. NOT the 6-digit code, NOT the otpauth:// URI. Leave null (the default) when 2FA is off — the provider validates length 16-32 even on empty strings, so providers.tf passes null through, not empty string."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}

# --- Garage (S3 object store) — per ADR 0002 + 0003 ---------------------------
# Garage runs as a single-node Container Manager workload on e4e-nas, data on
# the s3-data share (Btrfs with snapshots — /volume2/s3-data). Image pinned per
# ADR 0002.
#
# SECRETS ARE NOT TERRAFORM-MANAGED. The synology-community/synology provider
# treats `synology_container_project.content` (and the nested `secrets.content`
# and `configs.content`) as plain non-sensitive strings — they leak verbatim in
# plan/error/state output. So Garage's `garage.toml` (which contains rpc_secret,
# admin_token, metrics_token) is an OPERATOR-MANAGED file at
# /volume1/docker/garage/garage.toml that terraform only bind-mounts. See the
# Garage section in README.md for the operator workflow. Sub-PR 5 of #101
# (garage_config Ansible role) supersedes this with no_log + ansible-vault
# secret handling, after which the operator-managed step goes away.

variable "garage_image_tag" {
  description = "Garage container image tag. PINNED per ADR 0002. Bump deliberately + verify changelog (especially around storage migrations)."
  type        = string
  default     = "v1.1.0"
}
