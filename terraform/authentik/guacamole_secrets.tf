# Guacamole's Postgres password MOVED to the early terraform/secrets workspace so it
# exists before the fail-closed krg-prod vault-agent (P2) renders it. These `removed`
# blocks drop the resources from THIS workspace's state WITHOUT destroying the live KV
# entry (terraform/secrets owns it; the db_password is imported there to preserve it).
# Delete these blocks once the migration has applied in every environment. See
# terraform/secrets/README.md.
#
# (Guacamole's OIDC is implicit-flow — no client_secret consumed — so guacamole-oidc
# stays in vault_secrets.tf; only the DB password is a fail-closed consumer.)

removed {
  from = random_password.guacamole_db
  lifecycle {
    destroy = false
  }
}

removed {
  from = vault_kv_secret_v2.guacamole
  lifecycle {
    destroy = false
  }
}
