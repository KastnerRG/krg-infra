# Short-lived CLIENT cert for the provider to authenticate to the mTLS frontend.
# Issued from the lab CA's temporal-client role; krg-deploy's AppRole holds the
# pki_int/issue/temporal-client grant (terraform/openbao/pki.tf). The private key
# lands in tofu state — which is ENCRYPTED (ADR 0005, TOFU_STATE_PASSPHRASE).
# auto_renew re-issues before expiry so a re-run never presents an expired cert.
resource "vault_pki_secret_backend_cert" "deploy_client" {
  backend               = "pki_int"
  name                  = "temporal-client"
  common_name           = "krg-deploy"
  ttl                   = "1h"
  auto_renew            = true
  min_seconds_remaining = 1800 # re-issue when <30m remains
}

# ── Namespaces ────────────────────────────────────────────────────────────────
# Declarative Temporal namespaces. `retention` is in DAYS (the provider multiplies
# by 24h into the WorkflowExecutionRetentionPeriod). Add an entry to var.namespaces
# to create another; the key is the namespace name.
resource "temporal_namespace" "this" {
  for_each = var.namespaces

  name        = each.key
  description = each.value.description
  owner_email = each.value.owner_email
  retention   = each.value.retention
}
