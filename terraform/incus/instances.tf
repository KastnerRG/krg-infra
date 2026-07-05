# Tenant INSTANCES — the hardened slot the admin provisions (the boundary); the owning
# team deploys its app INTO the slot via repo-owns-deploy (ADR 0017 §8, the interior).
# Creating the VM is provisioning (admin); deploying into it is not.
#
# IMAGE-GATED: an instance materializes only for a tenant whose `image` is set to the
# golden-template image. Until that hardened template lands (ADR 0017 §7), tenants are
# BOUNDARY ONLY — project + quota, no instance — so this stays an empty for_each rather
# than a fabricated image reference. Set tenants.<name>.image to bring a slot up.
#
# isolation = "virtual-machine" (the default) gives semi-trusted developed code a
# SEPARATE KERNEL (ADR 0017 §4) — this needs nested virt on the krg-nat guest
# (/dev/kvm), the bring-up gate flagged on the host. "container" is reserved for
# admin-operated/trusted tenants.
resource "incus_instance" "tenant" {
  for_each = { for k, t in var.tenants : k => t if t.image != "" }

  name     = each.key
  project  = incus_project.tenant[each.key].name
  image    = each.value.image
  type     = each.value.isolation
  profiles = [incus_profile.baseline.name]

  # Per-instance limits mirror the project cap (defense in depth; the project quota is
  # the hard ceiling). Instance limits live in the config map (limits.cpu = a count,
  # limits.memory = a size).
  config = {
    "limits.cpu"    = tostring(each.value.cpu)
    "limits.memory" = each.value.memory
  }

  # Sized root disk — OVERRIDES the baseline profile's root device (an instance device of
  # the same name replaces the profile's wholesale, so pool + path are re-declared). The
  # project sets `limits.disk` (projects.tf), and Incus's project-quota accounting REJECTS
  # instance creation if any disk lacks a `size` ("has no size ... but the project has a
  # limits.disk set"). We size it to the tenant's own `disk` quota, so the VM's root block
  # device == the project cap (one instance ⇒ exactly at the limit, which Incus permits).
  # For a virtual-machine (the untrusted default, ADR 0017 §4) `size` is the block-device
  # size and works on the bootstrap `dir` pool — unlike a container FS quota, which the dir
  # driver can't enforce (revisit if a container tenant ever lands on the dir pool).
  device {
    name = "root"
    type = "disk"
    properties = {
      pool = var.storage_pool
      path = "/"
      size = each.value.disk
    }
  }

  # Pin the NAT address when the tenant is publicly exposed, so the ingress forward
  # (forwards.tf) has a STABLE target — a DHCP lease could move on reprovision and
  # silently break the forward. Overrides the baseline profile's DHCP eth0 (profiles.tf)
  # only when nat_ip is set; otherwise the instance keeps a DHCP lease.
  #
  # INGRESS (ADR 0017 §5) is an incus_network_forward (forwards.tf) DNAT'ing
  # incus_host_ip:<edge_port> → nat_ip:443, NOT a proxy device: a proxy device on a VM
  # supports ONLY nat mode ("Only NAT mode is supported for proxies on VM instances"),
  # and untrusted tenants are VMs (§4). A network forward is pure host-side DNAT — no
  # in-namespace forkproxy — so it works identically for VMs and containers. (Its earlier
  # "fails externally" result was CONFOUNDED by the Proxmox per-guest firewall dropping the
  # port upstream, since fixed in ansible krg-nat.fw; the forward itself creates + DNATs
  # fine on the host's own uplink IP.)
  dynamic "device" {
    for_each = each.value.nat_ip != "" ? [1] : []
    content {
      name = "eth0"
      type = "nic"
      properties = {
        network        = incus_network.nat.name
        "ipv4.address" = each.value.nat_ip
      }
    }
  }
}
