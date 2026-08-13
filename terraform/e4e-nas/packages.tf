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

# VPN Server (OpenVPN) — the remote-access path for off-campus SMB.
#
# Declared target + threat model: spec/e4e-nas/vpn.yml. Feed metadata confirmed
# on-box 2026-08-13: id `VPNCenter`, display name "VPN Server", 1.4.10-2984,
# available for synology_broadwell_3617xs on DSM 7.3.2, not deprecated.
#
# Installing is SAFE and inert: the package listens on nothing and opens no port
# until it is configured (spec/e4e-nas/vpn.yml is not consumed by any role yet).
# This resource exists FIRST on purpose — VPNCenter ships its own webapi libs,
# so `SYNO.VPNServer.*` cannot be enumerated until it is installed, and that
# discovery is what the `synology_vpn` role will be written against.
resource "synology_core_package" "vpn_server" {
  name = "VPNCenter"
}
