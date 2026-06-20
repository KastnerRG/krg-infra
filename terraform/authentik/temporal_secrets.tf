# Generated secret for Temporal — the Postgres database password.
#
# The OpenBao Agent on krg-prod renders this to /run/krg/temporal/db.env
# (POSTGRES_PASSWORD) and /run/krg/temporal/server.env (POSTGRES_PWD, Temporal's
# var name for the same value) — see krg.vaultAgent in
# nix/hosts/krg-prod/default.nix. Brand new + internal, so generating it here is
# pure creation, not a rotation of a live value. krg-prod's AppRole policy already
# reads secret/data/krg-prod/* (terraform/openbao/main.tf), so no policy change.
#
# Temporal's OIDC client secret is NOT here — Authentik mints it; it's captured in
# vault_secrets.tf "temporal_oidc" and rendered to /run/krg/temporal/ui.env.

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
