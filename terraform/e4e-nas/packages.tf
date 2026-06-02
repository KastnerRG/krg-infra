# DSM packages (Package Center) installed declaratively.
#
# `synology_core_package` installs a package by name/version. Useful for keeping
# Container Manager, Snapshot Replication, etc. present and pinned.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_package
#
# Template COMMENTED OUT — verify attribute names against the resource docs.

# resource "synology_core_package" "container_manager" {
#   name = "ContainerManager"
# }
