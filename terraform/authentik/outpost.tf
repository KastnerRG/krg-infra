# Proxy outpost — the authentik_proxy container on krg-prod registers here.
# Token flow today is MANUAL (no vault-agent/template wiring yet):
#   1. After apply, retrieve the token from Admin → Outposts → "View token"
#   2. (optional) Mirror it into vault for the future automated flow:
#        bao kv put secret/krg-prod/authentik-outpost-token token=<value>
#   3. Populate /var/lib/krg/krg-prod/.secrets/authentik_traefik_token.env
#      manually (AUTHENTIK_TOKEN=<token>) so the compose stack picks it up.

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
