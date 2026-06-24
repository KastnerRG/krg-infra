{inputs, ...}: {
  imports = [
    ../../profiles/server.nix
    inputs.disko.nixosModules.disko # declarative disk layout (ZFS-on-root)
    ./disko-config.nix
    ./hardware-configuration.nix
  ];

  # E4E (Engineers for Exploration) production host — project-specific and
  # project-developed services (e.g. FishSense). Lab-wide tools live on krg-prod;
  # this host starts empty because none of the current services are project-specific.
  krg.adminAccount = "e4e-admin";

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix) — isVM just
  # enables the QEMU guest agent. Proxmox adds the additive perimeter on top.
  krg.base.isVM = true;

  # Static networking — mirrors krg-prod (same /24, gateway, resolver list), just
  # .107 (reserved for e4e-prod in networks/trusted.json). krg.adClient prepends
  # the DC (krg-ldap, .109) as the primary resolver once joined; these stay as the
  # pre-join + fallback resolvers. NB: interface assumed `ens18` like the other
  # Proxmox VMs — confirm with `ip -o link` on the installer if the NIC enumerates
  # differently (machine-type dependent).
  networking = {
    hostName = "e4e-prod";
    domain = "ucsd.edu";
    useDHCP = false;
    interfaces.ens18.ipv4.addresses = [
      {
        address = "137.110.161.107";
        prefixLength = 24;
      }
    ];
    defaultGateway = "137.110.161.1";
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];
  };

  # E4E project services attach here as krg.composeStacks.<name> once defined,
  # following the krg-prod pattern (compose dir under nix/docker-compose/e4e-prod/,
  # working dir /var/lib/krg/e4e-prod). SSO can federate to krg-prod's Authentik.

  system.stateVersion = "25.11";
}
