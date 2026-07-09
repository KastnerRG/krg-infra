# The internal tenant NAT — the managed network the nix preseed deliberately does NOT
# create (ADR 0017 §3 assigns "managed network" to terraform). One shared bridge in
# the default project; tenant projects inherit it via features.networks=false
# (projects.tf). Incus runs DHCP + DNS on it and SNATs egress (ipv4.nat) — this is
# what "krg-nat" is named for. IPv6 off (v4-only RFC1918 tenancy in phase-1).
resource "incus_network" "nat" {
  name = var.nat_network_name
  type = "bridge"

  config = {
    "ipv4.address" = var.nat_ipv4_subnet
    "ipv4.nat"     = "true"
    "ipv6.address" = "none"
  }
}
