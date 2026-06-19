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

# Vaultwarden — Authentik mints this client secret (brand new). Consumed by the
# compose service as SSO_CLIENT_SECRET (populated into
# /var/lib/krg/krg-prod/.secrets/vaultwarden.env; see docs/vaultwarden-sso.md).
resource "vault_kv_secret_v2" "vaultwarden_oidc" {
  mount = "secret"
  name  = "krg-prod/vaultwarden-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.vaultwarden.client_id
    client_secret = authentik_provider_oauth2.vaultwarden.client_secret
    issuer_url    = "${var.authentik_url}/application/o/vaultwarden/"
  })
}

# Temporal — Authentik mints this client secret (brand new). The OpenBao Agent on
# krg-prod renders it to /run/krg/temporal/ui.env as TEMPORAL_AUTH_CLIENT_SECRET for
# the temporal-ui compose service (krg.vaultAgent in nix/hosts/krg-prod/default.nix).
resource "vault_kv_secret_v2" "temporal_oidc" {
  mount = "secret"
  name  = "krg-prod/temporal-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.temporal.client_id
    client_secret = authentik_provider_oauth2.temporal.client_secret
    issuer_url    = "${var.authentik_url}/application/o/temporal/"
  })
}

# garage-ui — the ONLY garage secret tofu generates (Authentik mints it; brand
# new, so writing it is pure creation, not a rotation of a live value). Path is
# secret/e4e-nas/* (not krg-prod/*) because the consumer is the NAS. The garage
# CLUSTER tokens (rpc/admin/metrics) already exist live and are NOT generated
# here — they're seeded into secret/e4e-nas/garage at their current values once
# (see ansible/synology/roles/synology_garage/README.md "Secrets").
# The synology_garage ansible role consumes both paths; krg-deploy's AppRole
# reads secret/data/e4e-nas/* (see ../openbao/main.tf).
resource "vault_kv_secret_v2" "garage_ui_oidc" {
  mount = "secret"
  name  = "e4e-nas/garage-ui-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.garage_ui.client_id
    client_secret = authentik_provider_oauth2.garage_ui.client_secret
    issuer_url    = "${var.authentik_url}/application/o/garage-ui/"
  })
}

# DSM web-login SSO — the e4e_nas OAuth2 provider (above) mints this; the
# synology_sso ansible role consumes it as DSM_SSO_OIDC_CLIENT_SECRET. Path is
# secret/e4e-nas/* (the NAS is the consumer); krg-deploy's AppRole reads
# secret/data/e4e-nas/* (../openbao/main.tf). Same shape as garage_ui_oidc.
resource "vault_kv_secret_v2" "dsm_sso_oidc" {
  mount = "secret"
  name  = "e4e-nas/dsm-sso-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.e4e_nas.client_id
    client_secret = authentik_provider_oauth2.e4e_nas.client_secret
    issuer_url    = "${var.authentik_url}/application/o/e4e-nas/"
  })
}

# Guacamole — stored for record/consistency. Guacamole's OIDC uses the IMPLICIT
# flow and does NOT consume a client_secret (only client_id + the public
# authorization/jwks/issuer endpoints), so nothing reads client_secret here; the
# value Guacamole actually needs (the Postgres password) is in guacamole_secrets.tf.
resource "vault_kv_secret_v2" "guacamole_oidc" {
  mount = "secret"
  name  = "krg-prod/guacamole-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.guacamole.client_id
    client_secret = authentik_provider_oauth2.guacamole.client_secret
    issuer_url    = "${var.authentik_url}/application/o/guacamole/"
  })
}

# (Proxmox no longer has an OIDC secret here — auth moved to a native PVE Active
# Directory realm; the bind-account password lives at secret/krg-prod/pve-ad-bind,
# seeded manually and read by the ansible pve_ad role. See docs/proxmox-auth.md.)

# outpost token: retrieved manually from Admin → Outposts → View token after apply.
# Store with: bao kv put secret/krg-prod/authentik-outpost-token token=<value>
