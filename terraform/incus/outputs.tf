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

output "tenant_edge_backends" {
  description = <<-EOT
    Map of tenant name → the `host:port` its zone edge should dial (the value for
    krg.edge.routes.<name>.backend in nix/modules/edge.nix). Only exposed tenants
    (edge_port > 0) appear. Incus DNATs this to the instance's nat_ip:443.
  EOT
  value = {
    for k, t in var.tenants : k => "${var.incus_host_ip}:${t.edge_port}"
    if t.edge_port > 0
  }
}
