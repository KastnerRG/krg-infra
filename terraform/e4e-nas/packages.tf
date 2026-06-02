# DSM packages (Package Center) installed declaratively.
#
# `synology_core_package` installs a package by name/version.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_package
#
# First-applied resource on this NAS. ContainerManager is the prerequisite for
# every other container project (Garage in particular — see ADR 0002 + 0003).
# Was NOT installed on e4e-nas as of 2026-06-02 — first `tofu apply` will
# install it. Allow a few minutes; DSM may need to download/extract the spk.
resource "synology_core_package" "container_manager" {
  name = "ContainerManager"
}
