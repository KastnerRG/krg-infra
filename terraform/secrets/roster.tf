# Roster startup secrets must exist BEFORE the krg-prod Agent runs.
# Adopt every live value on migration (including OIDC/session/LDAP); see
# docs/roster-openbao.md. The separate roster-crypto key is operator-seeded.

resource "random_password" "roster_db" {
  length  = 32
  special = false
  lifecycle {
    # Imports preserve live values even if Authentik used a different length.
    ignore_changes = [length, special]
  }
}

resource "random_password" "roster_session" {
  length  = 64
  special = false
  lifecycle {
    # Imports preserve live values even if Authentik used a different length.
    ignore_changes = [length, special]
  }
}

resource "random_password" "roster_ldap" {
  length  = 32
  special = false
  lifecycle {
    # Imports preserve live values even if Authentik used a different length.
    ignore_changes = [length, special]
  }
}

resource "random_password" "roster_oidc_client_secret" {
  length  = 64
  special = false
  lifecycle {
    # Imports preserve live values even if Authentik used a different length.
    ignore_changes = [length, special]
  }
}

resource "vault_kv_secret_v2" "roster" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/roster"
  data_json = jsonencode({
    db_password    = random_password.roster_db.result
    session_secret = random_password.roster_session.result
  })
}

resource "vault_kv_secret_v2" "roster_ldap" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/roster-ldap"
  data_json = jsonencode({
    bind_password = random_password.roster_ldap.result
  })
}

resource "vault_kv_secret_v2" "roster_oidc" {
  mount = "secret"
  name  = "krg-prod/authentik-managed/roster-oidc"
  data_json = jsonencode({
    client_id     = "e4e-roster"
    client_secret = random_password.roster_oidc_client_secret.result
    issuer_url    = "${var.authentik_url}/application/o/e4e-roster/"
  })
}
