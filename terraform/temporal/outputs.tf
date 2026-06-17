output "namespaces" {
  description = "Managed Temporal namespace names"
  value       = sort(keys(temporal_namespace.this))
}
