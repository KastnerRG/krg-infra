# terraform/secrets — the EARLY secret-generation workspace.
#
# Why this exists (the deploy-DAG fix): the fleet deploy runs NixOS members (P2,
# whose fail-closed krg.vaultAgent renders secrets) BEFORE OpenTofu (P3). When the
# secrets a service needs at startup are *generated* by the late terraform/authentik
# run, P2 reads them before they exist → the stack fails closed (the #320 outage,
# the openbao-migration manual ordering, etc.). This workspace generates every
# secret a P2/P1 consumer needs and writes it to OpenBao, and it depends ONLY on
# OpenBao — so it can run EARLY (between P1 and P2, wired in a follow-up). Then the
# fail-closed agent always finds its secrets pre-existing; terraform/authentik
# becomes config-only and merely *reads* the OIDC client_secret to set on its
# providers (it no longer mints them). See terraform/secrets/README.md.
#
# Auth: applied by the krg-deploy AppRole (VAULT_TOKEN), same as the other
# workspaces. No Authentik provider here — this workspace never talks to Authentik.

terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  # vault provider v5 requires Terraform/OpenTofu >= 1.11.
  required_version = ">= 1.11.0"
}

provider "vault" {
  address = var.vault_addr
  # Use the krg-deploy AppRole token directly — its policy lacks auth/token/create,
  # so the default child-token mint 403s. Same rationale as terraform/authentik.
  skip_child_token = true
}

provider "random" {}
