output "tenant_projects" {
  description = "Map of tenant name → its Incus project name (the tenancy boundary)."
  value       = { for k, p in incus_project.tenant : k => p.name }
}

output "tenant_zones" {
  description = "Map of tenant name → zone (which public edge routes to it: krg | e4e)."
  value       = { for k, t in var.tenants : k => t.zone }
}

output "nat_network" {
  description = "The managed internal NAT network name."
  value       = incus_network.nat.name
}
