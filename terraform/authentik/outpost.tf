# Proxy outpost — the authentik_proxy container on krg-prod registers here. Its API
# token is minted in IaC by outpost_tokens.tf (alongside the LDAP outpost's) and
# written to secret/krg-prod/authentik-managed/proxy-outpost-token; krg.vaultAgent
# renders it for the container. No manual "View token" step. (See the ⚠ CUTOVER note
# in outpost_tokens.tf for the one-time migration off the old pre-glob path.)

resource "authentik_outpost" "proxy" {
  name = "authentik Proxy Outpost"
  type = "proxy"

  protocol_providers = [
    authentik_provider_proxy.fishsense_orchestrator.id,
    authentik_provider_proxy.guacamole_gate.id,
  ]

  config = jsonencode({
    authentik_host          = var.authentik_url
    authentik_host_insecure = false
    log_level               = "info"
  })
}

# The outpost auto-creates a service account user (ak-outpost-<id>) and token —
# see header comment above for the manual retrieval / vault-store / env-file flow.
