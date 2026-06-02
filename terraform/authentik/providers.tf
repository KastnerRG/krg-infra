# Authentik configuration for KRG lab services.
# Applied from krg-deploy after Authentik is running.
#
# Bootstrap order:
#   1. Bring up the krg-prod compose stack (Authentik must be healthy)
#   2. Log into https://auth.fabricant.ucsd.edu as the akadmin account
#   3. Create a long-lived API token: Admin → System → API Tokens
#   4. Store it in vault:
#        bao kv put secret/krg-deploy/authentik-admin-token token=<token>
#   5. Set env vars and apply:
#        export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
#        export VAULT_TOKEN="<vault token>"
#        export TF_VAR_authentik_token="<authentik API token>"
#        export TF_VAR_ldap_bind_password="<authentik-bind password>"
#        tofu init && tofu apply
#
# This workspace both configures Authentik AND writes the generated
# OIDC client secrets into vault so downstream workspaces (grafana/)
# can read them without manual copy-paste.

terraform {
  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.8.0"
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

provider "vault" {
  address = var.vault_addr
}

provider "random" {}
