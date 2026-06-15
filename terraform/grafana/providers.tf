terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.0"
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
  # Use the supplied token (krg-deploy AppRole) directly — the AppRole policy doesn't
  # grant auth/token/create, so the provider's default child-token mint 403s. Same
  # fix as terraform/authentik/providers.tf.
  skip_child_token = true
}

# Grafana admin credentials — password read from vault so it never appears in env.
data "vault_kv_secret_v2" "grafana_admin" {
  mount = "secret"
  name  = "krg-prod/grafana-admin"
}

provider "grafana" {
  url  = var.grafana_url
  auth = "e4eadmin:${data.vault_kv_secret_v2.grafana_admin.data["password"]}"
}
