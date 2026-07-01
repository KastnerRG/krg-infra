{inputs, ...}: {
  imports = [
    # Hypervisor role (server tier + the guest-hosting substrate). Host-specifics below.
    ../../profiles/hypervisor.nix
    inputs.disko.nixosModules.disko # declarative disk layout (ZFS-on-root)
    ./disko-config.nix
    ./hardware-configuration.nix
  ];

  # The phase-1 Incus platform host (ADR 0017): runs the Incus daemon; student-project
  # tenant services AND self-serve VMs are Incus instances on its internal NAT. A tenant
  # is a terraform/incus instance on the `dir` pool — no per-tenant disk provisioning at
  # the hypervisor layer. The zone edges (krg-prod for *.krg, e4e-prod for *.e4e) route
  # to instances here; this host serves BOTH zones' tenants (one NAT, two edges).
  krg.adminAccount = "krg-admin";

  # Proxmox guest (phase-1 nested). The role profile owns base enable/autoUpgrade/
  # serviceHost; isVM is host-specific (phase-2 bare metal drops it).
  krg.base.isVM = true;

  # Static networking — mirrors the other lab VMs (same /24, gateway, resolver list),
  # .105 (krg-nat in networks/trusted.json; DNS-assigned krg-nat.ucsd.edu). krg.adClient
  # prepends the DC (krg-ldap, .109) as primary resolver once joined; these stay as
  # pre-join/fallback. NB: interface assumed `ens18` like the other Proxmox VMs —
  # CONFIRM with `ip -o link` on the installer if the NIC enumerates differently.
  networking = {
    hostName = "krg-nat";
    domain = "ucsd.edu";
    useDHCP = false;
    interfaces.ens18.ipv4.addresses = [
      {
        address = "137.110.161.105";
        prefixLength = 24;
      }
    ];
    defaultGateway = "137.110.161.1";
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];
  };

  # AD domain member (base.nix defaults krg.adClient.enable on). Domain join + keytab
  # are a bring-up step (docs/joining-a-host-to-the-domain.md), like the other hosts.
  krg.adClient.enable = true;

  # ── EDGE REACHABILITY — BRING-UP NETWORKING DECISION ─────────────────────────────
  # Incus SNATs tenant egress out of the managed NAT (incusbr0, RFC1918) — outbound
  # works out of the box. INGRESS (a zone edge dialing an instance to re-encrypt to
  # it) needs a path INTO that private subnet, which the edges don't have by default.
  # Phase-1 options, to settle at standup (ADR 0017 §3 — "instances bridged onto an
  # internal-only Proxmox bridge the edges also touch"):
  #   (a) a static route on each edge (krg-prod, e4e-prod) to the instance subnet via
  #       krg-nat's .124 address, OR
  #   (b) an Incus `proxy` device per exposed instance (forwards a krg-nat host port
  #       to the instance), OR
  #   (c) a shared internal Proxmox bridge all three VMs leg onto (the §3 phase-1
  #       sketch; egress SNAT done once).
  # Left undeclared here on purpose — it spans the Proxmox/ansible layer and the edge
  # configs, not just this host. Pick one with the operator before exposing a tenant.

  system.stateVersion = "25.11";
}
