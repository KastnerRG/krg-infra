# Incus OIDC client secret — the krg-nat incus daemon consumes it via a fail-closed
# vault-agent (a P2 consumer that renders at nix-switch, before Authentik is guaranteed
# up), so it is minted HERE (the early secret-generation workspace), NOT in
# terraform/authentik. Mirrors temporal-oidc: we mint; terraform/authentik READS it back
# to set on authentik_provider_oauth2.incus. Greenfield — no `tofu import` / no live
# migration — so it simply rotates on first apply (the OIDC client_secret is the
# rotate-on-apply case, per README.md, not the preserve case like a live DB password).
resource "random_password" "incus_oidc_client_secret" {
  length  = 64
  special = false # conservative charset — avoids env-file/quoting surprises downstream
}

resource "vault_kv_secret_v2" "incus_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/incus-oidc"
  data_json = jsonencode({
    client_id     = "incus"
    client_secret = random_password.incus_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/incus/"
  })
}
