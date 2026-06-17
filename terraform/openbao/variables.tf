variable "vault_addr" {
  description = "OpenBao API address"
  type        = string
  default     = "https://krg-vault.ucsd.edu:8200"
}

# ── PKI (lab-internal CA, see pki.tf) ────────────────────────────────────────

variable "pki_root_common_name" {
  description = "Subject CN of the lab-internal ROOT CA"
  type        = string
  default     = "KRG Lab Internal Root CA"
}

variable "pki_int_common_name" {
  description = "Subject CN of the lab-internal INTERMEDIATE CA (issues leaf certs)"
  type        = string
  default     = "KRG Lab Internal Intermediate CA"
}

variable "temporal_frontend_domains" {
  description = <<-EOT
    Names the temporal-frontend SERVER cert may carry. Must include whatever
    clients verify as the TLS server name: the docker service name `temporal`
    internally, plus the public name if the gRPC frontend is ever fronted.
  EOT
  type        = list(string)
  default     = ["temporal", "temporal.krg.ucsd.edu"]
}

variable "temporal_client_domains" {
  description = <<-EOT
    Identity names the temporal-client CLIENT certs may carry (cert CN/SAN).
    The frontend only checks the cert is CA-signed, but scoping the issuable
    names keeps the role least-privilege.
  EOT
  type        = list(string)
  default     = ["krg-deploy", "temporal-worker", "temporal-ui"]
}
