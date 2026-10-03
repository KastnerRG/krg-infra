# fishsense (Incus tenant) — platform-generated secrets, written EARLY so the tenant's
# fail-closed in-VM vault-agent finds them. See terraform/secrets/README.md.
#
# GENERATE-ONCE — NOT free to recreate. Once fishsense-services (v2) has converged,
# its db-bootstrap has set these as the Postgres login passwords of v2's roles. A
# fresh apply against state that lost them would ROTATE them; db-bootstrap re-asserts
# on the next converge, but every running consumer keeps the old env until recreated.
# deploy-tofu.sh refuses to create-over-an-existing OpenBao secret; adopt with
# TOFU_IMPORT (one line per key) rather than recreate.
#
#   tenants/fishsense/generated/services_db
#       {owner_password, app_password, backup_password, analytics_password, smoke_password}
#       Read by fishsense-services deploy/incus/secrets.nix (db-bootstrap: all five;
#       migrate: owner + backup; api + orchestrator: app; backup: backup; superset:
#       analytics; smoke: smoke). Under tenants/+/generated — krg-deploy's writer glob
#       for platform-generated tenant secrets (terraform/openbao/main.tf); the tenant
#       AppRole reads it via secret/data/tenants/fishsense/*.

locals {
  fishsense_services_db_roles = toset(["owner", "app", "backup", "analytics", "smoke"])
}

# [a-z0-9]{64}: safe unescaped in DSNs and the superset init's sed (v2 asks for "hex";
# this is the same safe charset, but a random_password, so it stays sensitive in plans).
resource "random_password" "fishsense_services_db" {
  for_each = local.fishsense_services_db_roles
  length   = 64
  special  = false
  upper    = false
  # `tofu import` can't recapture these (it defaults them true) → force-replace →
  # rotation. Ignore drift: generate-once, never auto-rotate (same guard as the others).
  lifecycle {
    ignore_changes = [special, upper]
  }
}

resource "vault_kv_secret_v2" "fishsense_services_db" {
  mount = "secret"
  name  = "tenants/fishsense/generated/services_db"
  data_json = jsonencode({
    for role in local.fishsense_services_db_roles :
    "${role}_password" => random_password.fishsense_services_db[role].result
  })
}
