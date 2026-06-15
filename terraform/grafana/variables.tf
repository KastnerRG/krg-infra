variable "grafana_url" {
  type    = string
  default = "https://monitoring.krg.ucsd.edu"
}

variable "authentik_url" {
  type    = string
  default = "https://auth.fabricant.ucsd.edu"
}

variable "vault_addr" {
  type    = string
  default = "https://krg-vault.ucsd.edu:8200"
}
