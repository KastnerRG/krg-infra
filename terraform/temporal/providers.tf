# Temporal namespace management for the KRG lab-wide workflow engine
# (workflows.krg.ucsd.edu). Applied from krg-deploy after the Temporal frontend is
# up with mTLS (docs/temporal-mtls.md) and the lab CA exists (terraform/openbao/pki.tf).
#
# Connectivity: the gRPC frontend (:7233) is published to the internet, gated by
# mutual TLS. This target authenticates with a SHORT-LIVED client cert issued from
# the lab CA's temporal-client role — minted here via the vault provider
# (krg-deploy's AppRole holds pki_int/issue/temporal-client). The frontend verifies
# the cert is CA-signed; reachability is not the control, the cert is.
#
# Run via deploy/deploy-tofu.sh (TOFU_TARGETS=temporal). It needs:
#   VAULT_TOKEN          krg-deploy AppRole token (to issue the client cert)
#   TF_VAR_vault_addr    OpenBao address (defaults to krg-vault)

terraform {
  required_providers {
    temporal = {
      source  = "platacard/temporal"
      version = "~> 0.19"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
  # vault provider v5 requires Terraform/OpenTofu >= 1.11.
  required_version = ">= 1.11.0"
}

provider "vault" {
  address = var.vault_addr
  # The krg-deploy AppRole token lacks auth/token/create, so the provider's default
  # child-token mint 403s — use the AppRole token directly (already short-lived).
  skip_child_token = true
}

# NOTE: this provider config DEPENDS ON a managed resource (the vault-issued client
# cert in main.tf), so OpenTofu configures it during APPLY, after the cert exists —
# expect a "configuration depends on values determined at apply" note on first plan.
# host is the dial address (krg-prod, resolvable now); the cert SAN is verified
# against server_name (the public name), independent of which address we dial.
provider "temporal" {
  host = var.temporal_host
  port = var.temporal_port
  tls {
    cert        = vault_pki_secret_backend_cert.deploy_client.certificate
    key         = vault_pki_secret_backend_cert.deploy_client.private_key
    ca          = vault_pki_secret_backend_cert.deploy_client.issuing_ca
    server_name = var.temporal_tls_server_name
  }
}
