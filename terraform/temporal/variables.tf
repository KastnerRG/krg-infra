variable "vault_addr" {
  description = "OpenBao API address (used to issue the temporal-client cert)"
  type        = string
  default     = "https://krg-vault.ucsd.edu:8200"
}

variable "temporal_host" {
  description = <<-EOT
    Dial address for the Temporal gRPC frontend. Defaults to krg-prod's internal
    name (resolvable from krg-deploy today, before the public workflows.krg.ucsd.edu
    record lands). The server cert is verified against temporal_tls_server_name, NOT
    this address — so dialing krg-prod while verifying workflows.krg.ucsd.edu is fine.
  EOT
  type        = string
  default     = "krg-prod.ucsd.edu"
}

variable "temporal_port" {
  description = "Temporal gRPC frontend port"
  type        = string
  default     = "7233"
}

variable "temporal_tls_server_name" {
  description = <<-EOT
    TLS server name verified against the frontend cert SAN — the public name workers
    connect to. Must be one of the SANs the temporal-frontend cert carries
    (terraform/openbao var.temporal_frontend_domains).
  EOT
  type        = string
  default     = "workflows.krg.ucsd.edu"
}

variable "namespaces" {
  description = <<-EOT
    Temporal namespaces to manage. Map key = namespace name. `retention` is in DAYS.
    Add an entry to create another namespace.
  EOT
  type = map(object({
    description = string
    owner_email = string
    retention   = optional(number, 30)
  }))
  default = {
    fishsense = {
      description = "FishSense project workflows (NRP cluster workers)"
      owner_email = "fishsense@ucsd.edu"
      retention   = 30
    }
  }
}
