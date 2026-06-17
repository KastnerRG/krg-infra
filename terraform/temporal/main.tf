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
