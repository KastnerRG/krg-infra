# Guacamole Postgres password — a fail-closed P2 consumer (krg-prod vault-agent renders
# it to web.env/db.env). PRESERVED on migration: postgres set it at init, so rotating
# would lock out the live DB — import the existing value (see README). Guacamole's OIDC
# is implicit-flow (no client_secret consumed), so the DB password is the only
# fail-closed secret here; guacamole-oidc stays in terraform/authentik.
resource "random_password" "guacamole_db" {
  length  = 32
  special = false
  # `tofu import` can't capture `special` (defaults it true) → would force-replace and
  # rotate the live DB password. Ignore input drift: generate-once, never auto-rotate.
  lifecycle {
    ignore_changes = [special]
  }
}

resource "vault_kv_secret_v2" "guacamole" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/guacamole"
  data_json = jsonencode({
    db_password = random_password.guacamole_db.result
  })
}
