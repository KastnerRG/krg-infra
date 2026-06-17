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

# mTLS client material — minted per-run by deploy/deploy-tofu.sh from the lab CA's
# temporal-client role and exported as TF_VAR_*. Defaults are empty so `tofu
# validate` works without them; an apply needs all three (the script sets them).
variable "temporal_client_cert" {
  description = "Client certificate PEM for mTLS to the frontend"
  type        = string
  sensitive   = true
  default     = ""
}

variable "temporal_client_key" {
  description = "Client private key PEM for mTLS to the frontend"
  type        = string
  sensitive   = true
  default     = ""
}

variable "temporal_ca_cert" {
  description = "Lab-internal CA PEM the frontend's server cert is verified against"
  type        = string
  default     = ""
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
