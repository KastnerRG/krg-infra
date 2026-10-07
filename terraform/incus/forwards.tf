# Tenant INGRESS — the settled edge→instance path (ADR 0017 §5).
#
# A zone edge (e4e-prod / krg-prod Traefik, nix/modules/edge.nix) must reach a tenant
# instance that lives on the internal Incus NAT (incusbr0, RFC1918). Egress is automatic
# (ipv4.nat SNATs instances OUT); INGRESS is what this file provides.
#
# WHY A NETWORK FORWARD (not a route, not a proxy device):
#   - Routing L3 INTO the managed NAT (a static route on the edge → incusbr0 via krg-nat)
#     does NOT work: Incus's own masquerade rule (`ip saddr 10.100.0.0/24 ip daddr !=
#     10.100.0.0/24 masquerade`) mangles the instance's RETURN path to the edge, and Incus
#     owns + regenerates that nftables table, so a nix-side exemption can't win. Validated
#     on-box: e4e-prod with a correct route saw 100% loss.
#   - A PROXY DEVICE (bind=host) only works on containers: on a VM it supports nat mode
#     only ("Only NAT mode is supported for proxies on VM instances"), and untrusted
#     tenants are VMs (§4). Validated on-box: the VM instance create was rejected.
# An `incus_network_forward` sidesteps both — pure host-side DNAT (no in-namespace
# forkproxy): the edge dials krg-nat's OWN uplink IP (same segment, no route), Incus DNATs
# to the instance, and conntrack handles the return. Proxmox-independent (nothing on the
# hypervisor — the platform is moving off Proxmox). (An earlier "fails externally" reading
# of this same forward was CONFOUNDED by the Proxmox per-guest firewall dropping the port
# upstream — since fixed in ansible krg-nat.fw; the forward creates + DNATs fine on the
# host's own uplink IP.)
#
# FLOW:  edge → incus_host_ip:edge_port  --Incus DNAT-->  nat_ip:443 (instance inner Traefik)
# The edge re-encrypts to the instance's `*.vm` cert (edge.nix serverName), verified by
# chain against the fleet CA — end-to-end TLS survives the DNAT.
#
# ONE FORWARD, ONE PORT PER TENANT. Incus allows a single network forward per LISTEN
# ADDRESS; every exposed tenant shares krg-nat's one uplink IP, so each tenant is a PORT
# ENTRY in that one forward (its own edge_port → its own nat_ip:443). This was a forward
# PER TENANT until the second exposed tenant (reference-manager, #562) hit "A forward
# for that listen address already exists" at create. `ports` updates in place in the
# lxc/incus provider (only network/listen_address/project/remote force replacement), so
# adding or removing a tenant edits this one forward without touching the others' DNATs.
locals {
  exposed_tenants = { for k, t in var.tenants : k => t if t.edge_port > 0 }
}

resource "incus_network_forward" "edge" {
  count = length(local.exposed_tenants) > 0 ? 1 : 0

  network        = incus_network.nat.name
  listen_address = var.incus_host_ip
  description    = "Edge ingress for Incus tenants (ADR 0017 §5): ${join(", ", sort(keys(local.exposed_tenants)))}"

  ports = [for k, t in local.exposed_tenants : {
    # description MUST be set to "" (not omitted). The lxc/incus provider marks the port
    # `description` optional-not-computed, so omitting it plans `null` — but Incus always
    # returns "" for a port description, so the post-apply read can't correlate the `ports`
    # set element ("Provider produced inconsistent result after apply: .ports: planned set
    # element ... does not correlate"). Setting "" makes plan == the value Incus returns.
    # (Which tenant a port belongs to is in the forward's description and var.tenants.)
    description    = ""
    protocol       = "tcp"
    listen_port    = tostring(t.edge_port)
    target_address = t.nat_ip
    target_port    = "443"
  }]
}

# Adopt the existing per-tenant forward (fishsense, the only one that ever applied) as
# the shared one: same network + listen_address, so this plans an IN-PLACE update that
# adds the new port(s), never a destroy/recreate of fishsense's live ingress.
moved {
  from = incus_network_forward.tenant["fishsense"]
  to   = incus_network_forward.edge[0]
}
