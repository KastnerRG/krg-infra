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
}
