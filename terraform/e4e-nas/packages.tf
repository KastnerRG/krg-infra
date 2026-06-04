# DSM packages (Package Center) installed declaratively.
#
# `synology_core_package` installs a Package Center package by name. The
# provider's schema exposes an optional `version` but we deliberately don't
# pin it: DSM's `hotfix-security` auto-update policy (see synology_dsm_updates)
# keeps installed packages on the latest DSM-compatible release, and pinning
# would silently lag those security fixes. Bump explicitly only if a known
# breaking release forces it.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_package
#
# First-applied resource on this NAS. ContainerManager is the prerequisite for
# every other container project (Garage in particular — see ADR 0002 + 0003).
# Was NOT installed on e4e-nas as of 2026-06-02 — first `tofu apply` will
# install it. Allow a few minutes; DSM may need to download/extract the spk.
resource "synology_core_package" "container_manager" {
  name = "ContainerManager"
}
