# Proxy outpost — the authentik_proxy container on krg-prod registers here. Its API
# token is minted in IaC by outpost_tokens.tf (alongside the LDAP outpost's) and
# written to secret/krg-prod/authentik-managed/proxy-outpost-token; krg.vaultAgent
# renders it for the container. No manual "View token" step. (See the ⚠ CUTOVER note
# in outpost_tokens.tf for the one-time migration off the old pre-glob path.)

resource "authentik_outpost" "proxy" {
  name = "authentik Proxy Outpost"
  type = "proxy"

  protocol_providers = [
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

# ── fishsense proxy outpost (CO-LOCATED with the tenant, hand-off Q1) ──────────────
# guacamole's app + outpost share krg-prod's Traefik, so its /outpost.goauthentik.io/*
# browser paths are served locally — automatic. fishsense's inner Traefik runs on its
# Incus slot (10.100.0.10), CROSS-HOST from the krg-prod outpost above: an
# api.fishsense.e4e.ucsd.edu request never touches krg-prod's Traefik, so the proxy
# provider's sign-in/callback paths would have nowhere to land → auth redirect loop.
#
# The Authentik-blessed fix for a remote app is a CO-LOCATED outpost: a
# ghcr.io/goauthentik/proxy container in the fishsense INTERIOR stack that dials OUT to
# auth.krg over the API websocket (egress is open; NO new inbound) and serves
# /outpost.goauthentik.io/* locally — making fishsense structurally identical to
# guacamole (outpost next to the app), with the correct Host header + cookie domain
# natively, no cross-host proxying. fishsense_orchestrator is therefore registered HERE,
# not on the shared `proxy` outpost above. The container reads its API token from
# secret/tenants/fishsense/oidc/proxy-outpost-token (minted in outpost_tokens.tf, rendered
# by the tenant's own vault-agent). See docs/handoff/fishsense-lite/HANDOFF.md §7.
resource "authentik_outpost" "fishsense_proxy" {
  name = "fishsense proxy outpost"
  type = "proxy"

  protocol_providers = [
    authentik_provider_proxy.fishsense_orchestrator.id,
  ]

  config = jsonencode({
    authentik_host          = var.authentik_url
    authentik_host_insecure = false
    log_level               = "info"
  })
}
