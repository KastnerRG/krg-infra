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
  # tenant instances over the OpenBao PKI). Each route is a per-name admin act gated on
  # its CNAME (ADR 0017 §6), and the explicit `hostnames` SAN list is the only thing that
  # drives issuance (no on-demand TLS). SSO forward-auth to krg-prod's central Authentik
  # is a follow-up seam.
  krg.edge = {
    enable = true;
    zone = "e4e";
    acme.email = "shperry@ucsd.edu";

    # PRODUCTION LE. The first-route staging bring-up (ADR 0017 §5 / runbook §5) is done:
    # e4e-prod's HTTP-01 path was validated against LE staging (issued + served the
    # `(STAGING) Let's Encrypt` cert for fishsense.e4e.ucsd.edu on 2026-07-05), so
    # `acme.staging` is now off for a real, trusted cert. Keep this the default; only flip
    # staging back on to debug a NEW first route on this edge.

    routes = {
      # fishsense — tenant #1 (docs/onboarding-fishsense.md §2c). ONLY the apex is listed:
      # `fishsense.e4e.ucsd.edu` is the only published CNAME so far; the api/
      # analytics SANs are added one-by-one as their CNAMEs land (the subtree HostRegexp
      # already matches every descendant, so each is a one-line `hostnames` addition — no
      # new route). backend = krg-nat:edge_port (the ingress network forward from
      # terraform/incus, output tenant_edge_backends.fishsense), NOT the instance address.
      # serverName defaults to "fishsense.vm" and reencrypt to true — the edge verifies the
      # tenant-internal cert by chain against the fleet CA. Until the fishsense interior is
      # up (its inner Traefik serving fishsense.vm), this backend is unreachable (the VM
      # drops :443); the public cert still issues (HTTP-01 is independent of the backend).
      fishsense = {
        subtree = "fishsense.e4e.ucsd.edu";
        hostnames = [
          "fishsense.e4e.ucsd.edu"
          "api.fishsense.e4e.ucsd.edu" # orchestrator API — gated in the inner Traefik (fishsense_orchestrator forward-auth)
          "analytics.fishsense.e4e.ucsd.edu" # Superset — OIDC (fishsense_analytics) in-app
        ];
        backend = "137.110.161.105:30443"; # krg-nat:30443 → proxy device → instance:443
      };
    };
  };

  system.stateVersion = "25.11";
}
