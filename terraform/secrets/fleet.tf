# Fleet's generated secrets, written EARLY so the fail-closed krg-prod vault-agent
# (P2) finds them before it renders. Fleet's SSO is SAML (no OIDC client secret), so
# there's nothing Authentik-related here; these are plain infra secrets. They live
# under krg-prod/authentik-managed/ only because that's the GLOBBABLE, policy-covered
# krg-prod namespace (#323) — not because Authentik touches them.
# See terraform/secrets/README.md.
#
# GENERATE-ONCE — NOT free to recreate. mysql_root_password/db_password are set into
# MySQL at data-dir init; server_private_key encrypts MDM assets at rest. Once Fleet has
# been deployed, the OpenBao secret is LIVE: a fresh apply MUST adopt the existing values
# via TOFU_IMPORT, never recreate them. Recreating locks MySQL out AND bricks MDM (and a
# value exposed during an open OOBE must be ROTATED off, not restored). deploy-tofu.sh
# refuses to create-over-an-existing OpenBao secret; the invariant lives here too.
#
#   krg-prod/authentik-managed/fleet  {mysql_root_password, db_password, server_private_key}
#       mysql_root_password — MySQL root (fleet_mysql), via MYSQL_ROOT_PASSWORD.
#       db_password         — the `fleet` DB role password; MySQL inits it
#                             (MYSQL_PASSWORD) and Fleet connects with it
#                             (FLEET_MYSQL_PASSWORD) — same value, two var names.
#       server_private_key  — FLEET_SERVER_PRIVATE_KEY; encrypts MDM certs/keys at
#                             rest. Generate-once and NEVER rotate — regenerating
#                             bricks MDM (Fleet can't decrypt enrolled devices' assets).

# ── MySQL root + `fleet` role passwords (generate-once; never auto-rotate) ────────
resource "random_password" "fleet_mysql_root" {
  length  = 32
  special = false
  # `special` is the one attribute a future `tofu import` can't recapture (defaults
  # true → force-replace → rotation), so ignore drift on it — same guard outline/
  # mlflow/temporal/guacamole use for their DB passwords.
  lifecycle {
    ignore_changes = [special]
  }
}

resource "random_password" "fleet_db" {
  length  = 32
  special = false
  # MySQL only reads MYSQL_PASSWORD at first data-dir init; regenerating would lock the
  # live `fleet` role out. Same ignore-`special` guard as above.
  lifecycle {
    ignore_changes = [special]
  }
}

# ── Fleet server private key (>=32 bytes; STABLE — rotating bricks MDM) ────────────
# Fleet uses this to encrypt MDM assets at rest. It MUST stay constant for the life of
# the deployment: generate-once and never replace, or enrolled devices' assets become
# undecryptable and MDM has to be torn down and re-enrolled. 32 ASCII chars = 32 bytes,
# which satisfies Fleet's ">= 32 bytes" requirement.
resource "random_password" "fleet_server_private_key" {
  length  = 32
  special = false
  lifecycle {
    ignore_changes = [special]
  }
}

resource "vault_kv_secret_v2" "fleet" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/fleet"
  data_json = jsonencode({
    mysql_root_password = random_password.fleet_mysql_root.result
    db_password         = random_password.fleet_db.result
    server_private_key  = random_password.fleet_server_private_key.result
  })
}
