# MLflow's generated secrets, written EARLY so the fail-closed krg-prod vault-agent
# (P2) finds them before it renders. MLflow is a brand-new bring-up (the stack was
# never deployed), so ALL of these are pure CREATES — there is no live DB password or
# rotated client_secret to preserve (unlike temporal/guacamole, which import their
# live DB password). See terraform/secrets/README.md.
#
#   krg-prod/authentik-managed/mlflow       {db_password, secret_key}
#       db_password — the Postgres role password (the mlflow + mlflow_auth databases
#                     share one role); embedded by vault-agent into the two URIs.
#       secret_key  — the mlflow-oidc-auth Flask session SECRET_KEY. Generate it once
#                     and keep it stable, else every container restart invalidates all
#                     logged-in sessions.
#   krg-prod/authentik-managed/mlflow-oidc  {client_id, client_secret, issuer_url}
#       The OIDC client. terraform/authentik READS client_secret back to set on
#       authentik_provider_oauth2.mlflow (it no longer mints it).

# ── Postgres password (generate-once; NEVER auto-rotate) ──────────────────────────
resource "random_password" "mlflow_db" {
  length  = 32
  special = false
  # Once mlflow_postgres initializes its data dir with this password, regenerating it
  # would lock the live DB out (postgres only reads POSTGRES_PASSWORD at first init).
  # `special` is the only attribute a future `tofu import` can't recapture (defaults
  # true → force-replace → rotation), so ignore drift on it — same guard temporal/
  # guacamole use for their DB passwords.
  lifecycle {
    ignore_changes = [special]
  }
}

# ── Flask session SECRET_KEY (stable so sessions survive a restart) ───────────────
resource "random_password" "mlflow_secret_key" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "mlflow" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/mlflow"
  data_json = jsonencode({
    db_password = random_password.mlflow_db.result
    secret_key  = random_password.mlflow_secret_key.result
  })
}

# ── OIDC client secret (we mint it; Authentik reads it back) ──────────────────────
# Length/charset kept conservative (no specials) to avoid env-file/quoting surprises
# downstream (it lands in /run/krg/mlflow/mlflow.env via vault-agent). The consumer
# reads client_secret from this KV; terraform/authentik sets the same value on
# authentik_provider_oauth2.mlflow via a data source.
resource "random_password" "mlflow_oidc_client_secret" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "mlflow_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/mlflow-oidc"
  data_json = jsonencode({
    client_id     = "mlflow"
    client_secret = random_password.mlflow_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/mlflow/"
  })
}
