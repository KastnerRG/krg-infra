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

    # The quota (ADR 0017 boundary). limits.cpu is a count; memory/disk are sizes.
    "limits.cpu"    = tostring(each.value.cpu)
    "limits.memory" = each.value.memory
    "limits.disk"   = each.value.disk
  }
}
