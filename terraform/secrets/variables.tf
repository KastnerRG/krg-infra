variable "vault_addr" {
  description = "OpenBao/Vault address"
  type        = string
  default     = "https://krg-vault.ucsd.edu:8200"
}

variable "authentik_url" {
  description = "Authentik base URL — used to construct the OIDC issuer_url stored alongside each client secret (must match terraform/authentik's var of the same name)."
  type        = string
  default     = "https://auth.krg.ucsd.edu"
}
