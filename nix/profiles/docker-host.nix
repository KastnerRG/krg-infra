# Docker-host mixin: the "this machine runs container workloads" capability.
#
# This is ORTHOGONAL to the base/server/workstation posture axis — a host opts
# into it by importing it alongside its role profile. It bundles the Docker daemon,
# the compose-stack runner, and the IPMI exporter that container-running infra
# hosts share. Pulled by the service + compute leaves; deliberately NOT by
# directory (the AD DC runs Samba natively, no Docker daemon) or by the plain
# server VMs that don't run compose stacks.
#
# The break-glass admin + krg.users live in base.nix (every host gets them), so
# they are not re-imported here.
{lib, ...}: {
  imports = [
    ../modules/docker.nix
    ../modules/services/compose-stack.nix
    ../modules/services/ipmi-exporter.nix
  ];

  krg.docker.enable = lib.mkDefault true;
}
