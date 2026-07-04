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

  # ── Human OIDC auth for the Incus API/UI (ADR 0017 / 0013) ───────────────────────
  # Incus is a PUBLIC OIDC client (authorization-code flow) — NO client secret (Incus 7.2
  # has no oidc.client.secret key; verified on-box). So there's nothing to render: just
  # issuer + clientId, applied to the running daemon by the incus-oidc-config oneshot
  # (modules/incus.nix). WHO may authenticate is gated at Authentik (the incus app →
  # Domain Admins); the Authentik provider is client_type = "public" to match.
  krg.incus.oidc = {
    issuer = "https://auth.krg.ucsd.edu/application/o/incus/"; # authentik app slug "incus"
    clientId = "incus";
  };

  # ── EDGE REACHABILITY — SETTLED (ADR 0017 §5) ────────────────────────────────────
  # Incus SNATs tenant egress out of the managed NAT (incusbr0, RFC1918) — outbound works
  # out of the box. INGRESS (a zone edge dialing an instance to re-encrypt to it) is an
  # Incus PROXY DEVICE per exposed tenant (terraform/incus): a real listening socket on
  # krg-nat's uplink IP:<edge_port> that forwards to the instance's inner service — the
  # edge dials that IP:port on its own segment (no route). krg.incus opens the reserved
  # ingress port range (default 30000-30999) to the zone edges (tenantIngressSources).
  # Chosen over: an L3 route INTO the NAT (broken by Incus's return-path masquerade,
  # validated on-box), an incus_network_forward (its DNAT only fires host-locally — external
  # edges saw the port filtered, validated on-box), and a shared Proxmox bridge (the platform
  # is moving off Proxmox). Expose a tenant with `edge_port` in terraform/incus var.tenants.

  system.stateVersion = "25.11";
}
