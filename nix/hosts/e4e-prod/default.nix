{inputs, ...}: {
  imports = [
    ../../profiles/services.nix
    ../../modules/edge.nix # krg.edge — the *.e4e zone public edge (ADR 0017 §5)
    inputs.disko.nixosModules.disko # declarative disk layout (ZFS-on-root)
    ./disko-config.nix
    ./hardware-configuration.nix
  ];

  # E4E (Engineers for Exploration) production host. Under ADR 0017 its role is the
  # **e4e DNS-zone edge**: it owns public ingress + Let's Encrypt issuance for
  # `*.e4e.ucsd.edu` and re-encrypts to the student-project tenant instances running on
  # the Incus platform (krg-nat). Lab-wide tools live on krg-prod (the krg-zone edge);
  # tenants no longer run compose ON this host — they're Incus instances it fronts.
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

  # The e4e zone edge. Stands up Traefik (LE-terminate on :80/:443 → re-encrypt to the
  # tenant instances over the OpenBao PKI). `routes` is EMPTY until tenant CNAMEs are
  # published — each route is a per-name admin act gated on its CNAME (ADR 0017 §6), and
  # the explicit SAN list is the only thing that drives issuance (no on-demand TLS). The
  # first tenant (fishsense) adds its route + backend in its own PR alongside the CNAME
  # request. SSO forward-auth to krg-prod's central Authentik is a follow-up seam.
  krg.edge = {
    enable = true;
    zone = "e4e";
    acme.email = "shperry@ucsd.edu";
    # acme.staging = true;  # flip ON when adding the first real route, validate, then OFF
    routes = {};
  };

  system.stateVersion = "25.11";
}
