# Write generated OIDC client secrets into vault.
#
# Consumption today is MIXED:
#   - terraform/grafana/ DOES read grafana-oidc from vault programmatically
#     (data "vault_kv_secret_v2" in grafana/sso.tf — wired through to the
#     grafana_sso_settings resource).
#   - Outline, MLflow, and any other compose-stack consumer still read from
#     local /var/lib/krg/krg-prod/.secrets/*.env files at container start.
#     The vault entries here are staged for future vault-agent/template
#     rendering of those files; until then they must be populated manually
#     (e.g. `bao kv get -field=client_secret secret/krg-prod/outline-oidc`
#     into the matching .secrets file).

resource "vault_kv_secret_v2" "grafana_oidc" {
  mount = "secret"
  name  = "krg-prod/grafana-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.grafana.client_id
    client_secret = authentik_provider_oauth2.grafana.client_secret
    issuer_url    = "${var.authentik_url}/application/o/grafana/"
  })
}

resource "vault_kv_secret_v2" "outline_oidc" {
  mount = "secret"
  name  = "krg-prod/outline-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.outline.client_id
    client_secret = authentik_provider_oauth2.outline.client_secret
    issuer_url    = "${var.authentik_url}/application/o/outline/"
  })
}

resource "vault_kv_secret_v2" "mlflow_oidc" {
  mount = "secret"
  name  = "krg-prod/mlflow-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.mlflow.client_id
    client_secret = authentik_provider_oauth2.mlflow.client_secret
    issuer_url    = "${var.authentik_url}/application/o/mlflow/"
  })
}

resource "vault_kv_secret_v2" "roster_oidc" {
  mount = "secret"
  name  = "krg-prod/roster-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.e4e_roster.client_id
    client_secret = authentik_provider_oauth2.e4e_roster.client_secret
    issuer_url    = "${var.authentik_url}/application/o/e4e-roster/"
  })
}

# outpost token: retrieved manually from Admin → Outposts → View token after apply.
# Store with: bao kv put secret/krg-prod/authentik-outpost-token token=<value>
