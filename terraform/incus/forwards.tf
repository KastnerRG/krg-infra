# Tenant INGRESS — the settled edge→instance path (ADR 0017 §5).
#
# A zone edge (e4e-prod / krg-prod Traefik, nix/modules/edge.nix) must reach a tenant
# instance that lives on the internal Incus NAT (incusbr0, RFC1918). Egress is automatic
# (ipv4.nat SNATs instances OUT); INGRESS is what this file provides.
#
# WHY A NETWORK FORWARD, NOT A ROUTE. Routing L3 INTO the managed NAT (a static route on
# the edge → incusbr0 via krg-nat) does NOT work: Incus's own masquerade rule
# (`ip saddr 10.100.0.0/24 ip daddr != 10.100.0.0/24 masquerade`) mangles the instance's
# RETURN path to the edge, and Incus owns + regenerates that nftables table, so a nix-side
# exemption can't win. Validated on-box: e4e-prod with a correct route saw 100% loss.
# An `incus_network_forward` sidesteps it entirely — the edge dials krg-nat's OWN uplink IP
# (same segment, no route), Incus DNATs to the instance, and conntrack handles the return.
# It's also Proxmox-independent (nothing on the hypervisor — the platform is moving off
# Proxmox), which a shared-bridge alternative would not be.
#
# FLOW:  edge → incus_host_ip:edge_port  --Incus DNAT-->  nat_ip:443 (instance inner Traefik)
# The edge re-encrypts to the instance's `*.vm` cert (edge.nix serverName), verified by
# chain against the fleet CA — end-to-end TLS survives the DNAT. Per exposed tenant: one
# forward, one distinct port on krg-nat's single IP (edge_port), one pinned target (nat_ip).
resource "incus_network_forward" "tenant" {
  for_each = { for k, t in var.tenants : k => t if t.edge_port > 0 }

  network        = incus_network.nat.name
  listen_address = var.incus_host_ip
  description    = "Edge ingress for tenant ${each.key} (ADR 0017 §5)"

  ports = [{
    protocol       = "tcp"
    listen_port    = tostring(each.value.edge_port)
    target_address = each.value.nat_ip
    target_port    = "443"
  }]
}
