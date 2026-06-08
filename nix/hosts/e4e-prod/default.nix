{...}: {
  imports = [
    ../../profiles/server.nix
    ./hardware-configuration.nix
  ];

  # E4E (Engineers for Exploration) production host — project-specific and
  # project-developed services (e.g. FishSense). Lab-wide tools live on krg-prod;
  # this host starts empty because none of the current services are project-specific.
  krg.adminAccount = "e4e-admin";

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix) — isVM just
  # enables the QEMU guest agent. Proxmox adds the additive perimeter on top.
  krg.base.isVM = true;

  networking = {
    hostName = "e4e-prod";
    domain = "ucsd.edu";
  };

  # E4E project services attach here as krg.composeStacks.<name> once defined,
  # following the krg-prod pattern (compose dir under nix/docker-compose/e4e-prod/,
  # working dir /var/lib/krg/e4e-prod). SSO can federate to krg-prod's Authentik.

  system.stateVersion = "25.11";
}
