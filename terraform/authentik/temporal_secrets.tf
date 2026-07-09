# Temporal's generated secrets (Postgres password + OIDC client secret) MOVED to the
# early terraform/secrets workspace so they exist before the fail-closed krg-prod
# vault-agent (P2) renders them — terraform/authentik (P3) runs too late to generate
# them. See terraform/secrets/README.md.
#
# These `removed` blocks drop the resources from THIS workspace's state WITHOUT
# destroying the live KV entries (terraform/secrets now owns them; the db_password is
# imported there to preserve it). Delete these blocks once the migration has applied
# in every environment.
#
# The provider still consumes the client_secret — see the data source +
# `client_secret =` on authentik_provider_oauth2.temporal in applications_krg.tf.

removed {
  from = random_password.temporal_db
  lifecycle {
    destroy = false
  }
}

removed {
  from = vault_kv_secret_v2.temporal
  lifecycle {
    destroy = false
  }
}
