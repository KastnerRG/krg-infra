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
