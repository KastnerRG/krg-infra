# Temporal secrets — PILOT for the generation-relocation pattern (see README.md).
#
# Two secrets, two migration modes:
#   - temporal (db_password): PRESERVED on migration. Postgres set this password at
#     init; regenerating it would lock out the live DB. Import the existing value
#     (runbook in README) so the first apply is a no-op on this value.
#   - temporal-oidc (client_secret): ROTATED on migration. Authentik minted it today;
#     we take ownership by generating a fresh one and setting it on the provider in
#     the same deploy run. Both sides (Authentik provider + the temporal-ui consumer)
#     pick up the new value within the run — the eventually-consistent-within-one-run
#     SSO window is acceptable (and only happens on this one migration).

# ── Postgres password (preserved) ────────────────────────────────────────────────
resource "random_password" "temporal_db" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "temporal" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/temporal"
  data_json = jsonencode({
    db_password = random_password.temporal_db.result
  })
}

# ── OIDC client secret (we now mint it; Authentik reads it back) ──────────────────
# Length/charset kept conservative (no specials) to avoid env-file/quoting surprises
# downstream. The consumer reads client_secret from this KV; terraform/authentik sets
# the same value on authentik_provider_oauth2.temporal via a data source.
resource "random_password" "temporal_oidc_client_secret" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "temporal_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/temporal-oidc"
  data_json = jsonencode({
    client_id     = "temporal"
    client_secret = random_password.temporal_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/temporal/"
  })
}
