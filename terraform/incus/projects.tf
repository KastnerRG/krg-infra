# Per-tenant Incus PROJECT + quota — the tenancy boundary. One project per tenant
# isolates its instances, and limits.* caps its aggregate footprint so one tenant
# can't starve prod on the shared phase-1 host (ADR 0017 §"per-tenant quotas exist";
# a fleet-level cap is a tracked follow-up). Features are shared down from the default
# project so there's ONE NAT network and ONE baseline profile/image set fleet-wide —
# the project boundary is for tenancy + quota, not for forking the platform baseline.
resource "incus_project" "tenant" {
  for_each = var.tenants

  name        = each.key
  description = "Tenant project for ${each.key} (zone ${each.value.zone}) — ADR 0017"

  config = {
    # Share the platform baseline from the default project (one NAT, one image set,
    # one set of baseline profiles) — tenancy isolation without baseline drift.
    "features.images"          = "false"
    "features.networks"        = "false"
    "features.profiles"        = "false"
    "features.storage.volumes" = "false"

    # The quota (ADR 0017 boundary). limits.cpu is a count; memory is a size.
    "limits.cpu"    = tostring(each.value.cpu)
    "limits.memory" = each.value.memory

    # NO project-aggregate limits.disk: the tenant's disk cap is the instance root-disk
    # `size` (= each.value.disk, instances.tf), which for a VM is a HARD block-device
    # ceiling the tenant can't exceed — and tenants have no Incus API access to attach
    # extra volumes (they deploy INTO their one slot via compose). A project limits.disk
    # equal to that root size would double-count the sole instance's root against itself
    # and Incus rejects creation ("Reached maximum aggregate value for limits.disk");
    # giving it headroom would just be an arbitrary magic number. So the root `size` is
    # the disk boundary; the project caps CPU/memory aggregate. Revisit (a real project
    # disk cap over headroom) only if a tenant ever runs multiple instances/volumes.
  }
}
