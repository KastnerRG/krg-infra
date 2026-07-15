# FishSense off-prem data-worker — non-interactive access to the orchestrator API.
#
# The data-worker runs on NRP/Nautilus (namespace e4e-fishsense), OFF our slot, so it
# can't reach `fishsense-api:8000` on the interior docker network the way the in-slot
# api-worker does — it must call the PUBLIC API at api.fishsense.e4e.ucsd.edu, which is
# gated by the `fishsense_orchestrator` proxy provider (forward_single) on the co-located
# `fishsense_proxy` outpost. The API itself has no auth of its own; the proxy IS the wall.
#
# An authentik proxy provider DOES accept non-interactive clients — but its HTTP Basic
# path validates the password as an authentik APP PASSWORD (run through the internal
# OAuth2 machine-to-machine flow), NOT the account's raw AD/Samba password. Sending the
# raw password is treated as invalid → authentik falls back to the interactive flow →
# 302 (issue #483: valid AD creds 302 identically to anonymous). So the fix is to mint an
# app-password token for the service account and have the SDK send THAT as the Basic
# password; the AD password stays the credential for the account's other domain resources.
#
# svc_fishsense is a real KRG.LOCAL service account (declared in spec/krg-ad/
# service-accounts.yml, member_of "FishSense") synced into authentik by the samba_ad LDAP
# source (ldap.tf). Its "FishSense" membership syncs too, so the existing app-access
# binding (app_access.tf: fishsense_orchestrator = ["FishSense"]) already admits it — no
# new access policy needed. Being a proper AD principal (not a native authentik user) is
# required so the same identity can reach other domain resources.

data "authentik_user" "svc_fishsense" {
  username = "svc_fishsense" # sAMAccountName as synced by the samba_ad source
}

# App-password token: the credential the proxy's HTTP Basic path validates. Non-expiring
# to match the outpost-token pattern (rotation is a follow-up). retrieve_key reads the
# generated key back into (encrypted) state so we can write it to OpenBao.
resource "authentik_token" "fishsense_data_worker" {
  identifier   = "fishsense-data-worker-apppw"
  user         = data.authentik_user.svc_fishsense.id
  intent       = "app_password"
  expiring     = false
  retrieve_key = true
  description  = "FishSense NRP data-worker app-password — HTTP Basic to the orchestrator API proxy provider (managed by terraform/authentik/fishsense_data_worker.tf; issue #483)"
}

# Write to the tenant KV under .../oidc/* — the ONLY tenant prefix the terraform/authentik
# writer glob (`tenants/+/oidc` in terraform/openbao/main.tf) permits, and the right
# semantic bucket (an authentik-issued SSO credential, alongside proxy-outpost-token). No
# openbao policy change. NRP is off our OpenBao, so delivery to the NRP k8s Secret
# `fishsense-data-worker-secrets` is a manual operator hand-off (same interim pattern as
# the ADR-0023 Temporal client cert) — this leaf is the durable source of record.
resource "vault_kv_secret_v2" "fishsense_data_worker_apppw" {
  mount = "secret"
  name  = "tenants/fishsense/oidc/data-worker-apppw"
  data_json = jsonencode({
    app_password = authentik_token.fishsense_data_worker.key
  })
}
