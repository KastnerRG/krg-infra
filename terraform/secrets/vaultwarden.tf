# Vaultwarden OIDC client secret — a fail-closed P2 consumer (krg-prod vault-agent
# renders it to vaultwarden.env as SSO_CLIENT_SECRET). We now mint it; terraform/authentik
# reads it back to set on the provider. ROTATES on migration (Authentik provider + the
# consumer converge within the one deploy run). No DB password here — Vaultwarden's data
# store isn't a tofu-managed Postgres in this stack.
resource "random_password" "vaultwarden_oidc_client_secret" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "vaultwarden_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/vaultwarden-oidc"
  data_json = jsonencode({
    client_id     = "vaultwarden"
    client_secret = random_password.vaultwarden_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/vaultwarden/"
  })
}
