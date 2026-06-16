# Why hashicorp/vault and not an openbao provider?
#
# OpenBao is a community fork of HashiCorp Vault and deliberately maintains
# full API compatibility — same endpoints, same token format, same secret
# engine APIs. The OpenBao project considered publishing a dedicated
# Terraform/OpenTofu provider but decided against it while the APIs remain
# identical (see https://github.com/openbao/openbao/issues/339 and
# https://github.com/orgs/openbao/discussions/637). Their official guidance
# is to use hashicorp/vault. The provider has no idea whether it is talking
# to Vault or OpenBao — it just speaks the API.
#
# Run from krg-deploy. Before applying, export:
#   export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
#   export VAULT_TOKEN="<root or admin token>"

terraform {
  required_providers {
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
}
