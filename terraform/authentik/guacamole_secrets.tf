# Generated secret for Guacamole — the Postgres database password.
#
# This is the value the OpenBao Agent on krg-prod renders to
# /run/krg/guacamole/guacamole.env (krg.vaultAgent in nix/hosts/krg-prod/default.nix),
# which both the guacamole webapp (POSTGRESQL_PASSWORD) and the postgres container
# (POSTGRES_PASSWORD) read. Brand new + internal, so generating it here is pure
# creation, not a rotation of a live value. krg-prod's AppRole policy already reads
# secret/data/krg-prod/* (terraform/openbao/main.tf), so no policy change is needed.
#
# Guacamole's OIDC client secret is NOT here — implicit flow doesn't use one (see
# vault_secrets.tf "guacamole_oidc").

resource "random_password" "guacamole_db" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "guacamole" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/guacamole"
  data_json = jsonencode({
    db_password = random_password.guacamole_db.result
  })
}
