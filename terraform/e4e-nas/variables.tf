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
# ADR 0002. Secrets supplied via TF_VAR_garage_* env vars (see
# terraform.tfvars.example) — never written to a .tfvars file on disk.

variable "garage_image_tag" {
  description = "Garage container image tag. PINNED per ADR 0002. Bump deliberately + verify changelog (especially around storage migrations)."
  type        = string
  default     = "v1.1.0"
}

variable "garage_rpc_secret" {
  description = "Garage RPC shared secret — hex string used to authenticate inter-node RPC. Even on a single-node cluster Garage requires it. Generate with `openssl rand -hex 32` and export as TF_VAR_garage_rpc_secret. Lands in state — keep state encrypted."
  type        = string
  sensitive   = true
}

variable "garage_admin_token" {
  description = "Garage admin API token — bearer for the admin API on :3903 (bucket/key/layout management). Generate with `openssl rand -hex 32` and export as TF_VAR_garage_admin_token. Lands in state."
  type        = string
  sensitive   = true
}

variable "garage_metrics_token" {
  description = "Garage metrics API token — bearer for Prometheus scrape on :3903/metrics. Generate with `openssl rand -hex 32` and export as TF_VAR_garage_metrics_token. Lands in state."
  type        = string
  sensitive   = true
}
