# Temporal namespace management for the KRG lab-wide workflow engine
# (workflows.krg.ucsd.edu). Applied from krg-deploy after the Temporal frontend is
# up with mTLS (docs/temporal-mtls.md) and the lab CA exists (terraform/openbao/pki.tf).
#
# Connectivity: the gRPC frontend (:7233) is published to the internet, gated by
# mutual TLS. This target authenticates with a SHORT-LIVED client cert from the lab
# CA's temporal-client role. The cert is minted by deploy/deploy-tofu.sh (which holds
# the krg-deploy AppRole) and passed in as vars — NOT issued by an in-tofu resource:
# the provider builds its TLS client at CONFIGURE time, so the cert must be known at
# plan time, which a "known after apply" resource attribute is not (it fails with
# "tls: failed to find any PEM data"). The frontend verifies the cert is CA-signed;
# reachability is not the control, the cert is.
#
# Run via deploy/deploy-tofu.sh (TOFU_TARGETS=temporal). It needs:
#   VAULT_TOKEN   krg-deploy AppRole token (to mint the client cert via bao)

terraform {
  required_providers {
    temporal = {
      source  = "platacard/temporal"
      version = "~> 0.19"
    }
  }
  required_version = ">= 1.6.0"
}

# host is the dial address (krg-prod, resolvable now); the cert SAN is verified
# against server_name (the public name), independent of which address we dial.
provider "temporal" {
  host = var.temporal_host
  port = var.temporal_port
  tls {
    cert        = var.temporal_client_cert
    key         = var.temporal_client_key
    ca          = var.temporal_ca_cert
    server_name = var.temporal_tls_server_name
  }
}
