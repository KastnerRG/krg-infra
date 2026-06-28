# The baseline profile — wires every tenant slot to the platform: a NIC on the NAT
# and a root disk on the bootstrap pool. The HARDENING (AD-join, key-only SSH,
# auto-upgrade, monitoring, in-guest firewall, central logging — ADR 0017 §7 "born
# from the hardened template") comes from the golden-template IMAGE, not here; the
# profile is the platform-attachment layer. One shared profile in the default project;
# tenant projects inherit it (features.profiles=false).
resource "incus_profile" "baseline" {
  name        = "krg-baseline"
  description = "Platform baseline: NAT nic + root disk on the bootstrap pool (ADR 0017)"

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = incus_network.nat.name
    }
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = var.storage_pool
      path = "/"
    }
  }
}
