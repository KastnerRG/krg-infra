# Outline's generated secrets, written EARLY so the fail-closed krg-prod vault-agent
# (P2) finds them before it renders. See terraform/secrets/README.md.
#
# GENERATE-ONCE — NOT free to recreate. db_password is set into Postgres at data-dir
# init; secret_key/utils_secret encrypt DB columns at rest. Once Outline has been
# deployed, the OpenBao secret is LIVE: a fresh apply MUST adopt the existing values via
# TOFU_IMPORT, never recreate them. Recreating rotates the DB password (auth lockout)
# AND the encryption keys (existing data becomes undecryptable). This bit us once — a
# deploy ran against state that had lost these resources and regenerated all three.
# deploy-tofu.sh now refuses to create-over-an-existing OpenBao secret; the invariant
# lives here too: treat every secret below as import-to-preserve, not "pure create".
#
#   krg-prod/authentik-managed/outline       {db_password, secret_key, utils_secret}
#       db_password  — the Postgres role password (outline_user); embedded by
#                      vault-agent into DATABASE_URL.
#       secret_key   — Outline's SECRET_KEY (signs sessions/cookies). MUST be a
#                      hex-encoded 32-byte string (the app hex-decodes it), so it's a
#                      random_id .hex, NOT a random_password. Keep it stable, else
#                      every restart invalidates existing sessions.
#       utils_secret — Outline's UTILS_SECRET (signs internal tokens). Same hex-32
#                      requirement and stability rule as secret_key.
#   krg-prod/authentik-managed/outline-oidc  {client_id, client_secret, issuer_url}
#       The OIDC client. terraform/authentik READS client_secret back to set on
#       authentik_provider_oauth2.outline (it no longer mints it).

# ── Postgres password (generate-once; NEVER auto-rotate) ──────────────────────────
resource "random_password" "outline_db" {
  length  = 32
  special = false
  # Once outline_postgres initializes its data dir with this password, regenerating it
  # would lock the live DB out (postgres only reads POSTGRES_PASSWORD at first init).
  # `special` is the only attribute a future `tofu import` can't recapture (defaults
  # true → force-replace → rotation), so ignore drift on it — same guard temporal/
  # guacamole/mlflow use for their DB passwords.
  lifecycle {
    ignore_changes = [special]
  }
}

# ── SECRET_KEY / UTILS_SECRET (hex-32, stable so sessions survive a restart) ──────
# random_id .hex gives a hex-encoded byte_length-byte string — exactly what Outline's
# `openssl rand -hex 32` docs require. random_password would emit a non-hex charset
# that Outline rejects when it hex-decodes these at boot.
resource "random_id" "outline_secret_key" {
  byte_length = 32
}

resource "random_id" "outline_utils_secret" {
  byte_length = 32
}

resource "vault_kv_secret_v2" "outline" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/outline"
  data_json = jsonencode({
    db_password  = random_password.outline_db.result
    secret_key   = random_id.outline_secret_key.hex
    utils_secret = random_id.outline_utils_secret.hex
  })
}

# ── OIDC client secret (we mint it; Authentik reads it back) ──────────────────────
# Length/charset kept conservative (no specials) to avoid env-file/quoting surprises
# downstream (it lands in /run/krg/outline/outline.env via vault-agent). The consumer
# reads client_secret from this KV; terraform/authentik sets the same value on
# authentik_provider_oauth2.outline via a data source.
resource "random_password" "outline_oidc_client_secret" {
  length  = 64
  special = false
}

resource "vault_kv_secret_v2" "outline_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/outline-oidc"
  data_json = jsonencode({
    client_id     = "outline"
    client_secret = random_password.outline_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/outline/"
  })
}
