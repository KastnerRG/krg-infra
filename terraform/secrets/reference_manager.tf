# reference-manager (Incus tenant, bib.krg.ucsd.edu) — platform-generated secrets,
# written EARLY so the tenant's fail-closed in-VM vault-agent finds them. See README.md.
#
# GENERATE-ONCE — NOT free to recreate. Once the slot has converged:
#   * db_password is the `refman` Postgres role's password, set by the postgres image
#     at data-dir init. A rotation locks the API out of its database (the outline/fleet
#     class of outage) — the interior has no bootstrap that re-asserts it.
#   * session_secret signs the API's session cookies (Starlette SessionMiddleware); a
#     rotation only logs everyone out, but keep it stable anyway.
# deploy-tofu.sh refuses to create-over-an-existing OpenBao secret; adopt with
# TOFU_IMPORT (one line per key) rather than recreate.
#
#   tenants/reference-manager/generated/app   {db_password, session_secret}
#       Read by the interior's deploy/incus/secrets.nix (postgres: db_password; api:
#       both). Under tenants/+/generated — krg-deploy's writer glob for platform-
#       generated tenant secrets (terraform/openbao/main.tf), so no openbao apply; the
#       tenant AppRole reads it via secret/data/tenants/reference-manager/*.

# [a-z0-9]{64}: safe unescaped in the asyncpg DSN the API is handed.
resource "random_password" "reference_manager_db" {
  length  = 64
  special = false
  upper   = false
  # `tofu import` can't recapture these (it defaults them true) → force-replace →
  # rotation. Ignore drift: generate-once, never auto-rotate (same guard as the others).
  lifecycle {
    ignore_changes = [special, upper]
  }
}

resource "random_password" "reference_manager_session" {
  length  = 64
  special = false
  upper   = false
  lifecycle {
    ignore_changes = [special, upper]
  }
}

resource "vault_kv_secret_v2" "reference_manager_app" {
  mount = "secret"
  name  = "tenants/reference-manager/generated/app"
  data_json = jsonencode({
    db_password    = random_password.reference_manager_db.result
    session_secret = random_password.reference_manager_session.result
  })
}
