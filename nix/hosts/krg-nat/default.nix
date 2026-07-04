{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    # Hypervisor role (server tier + the guest-hosting substrate). Host-specifics below.
    ../../profiles/hypervisor.nix
    ../../modules/services/vault-agent.nix # renders the Incus OIDC client secret (below)
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
  # vault-agent renders the OIDC client secret (minted by terraform/secrets, path
  # secret/krg-prod/authentik-managed/incus-oidc) to a tmpfs file; the incus-oidc-config
  # oneshot (modules/incus.nix) applies issuer/client.id/client.secret to the running
  # daemon. AppRole = "krg-nat" (terraform/openbao). The secret is fail-closed
  # (errorOnMissingKey default true), so terraform/secrets MUST have minted incus-oidc
  # before this host deploys — the deploy phase order (secrets in 1.5, systems in 2)
  # guarantees that; if landing PRs out of order, apply the openbao/secrets side first.
  krg.vaultAgent = {
    enable = true; # roleName defaults to the hostname ("krg-nat")
    renders = [
      {
        destination = "/run/krg/incus/oidc-client-secret";
        perms = "0600";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/incus-oidc" }}{{ .Data.data.client_secret }}{{- end }}
        '';
        # Re-apply the secret to the daemon when it rotates (agent fires this on change).
        reloadCommand = "${pkgs.systemd}/bin/systemctl restart incus-oidc-config.service || true";
      }
    ];
  };

  krg.incus.oidc = {
    issuer = "https://auth.krg.ucsd.edu/application/o/incus/"; # authentik app slug "incus"
    clientId = "incus";
    clientSecretFile = "/run/krg/incus/oidc-client-secret";
  };

  # ── EDGE REACHABILITY — SETTLED (ADR 0017 §5) ────────────────────────────────────
  # Incus SNATs tenant egress out of the managed NAT (incusbr0, RFC1918) — outbound
  # works out of the box. INGRESS (a zone edge dialing an instance to re-encrypt to it)
  # is an `incus_network_forward` declared in terraform/incus (forwards.tf): the edge
  # dials krg-nat's OWN uplink IP:port on its own segment (no route), and Incus DNATs to
  # the instance's pinned NAT address:443. Decided this way because an L3 route INTO the
  # NAT is broken by Incus's own return-path masquerade (validated on-box: 100% loss),
  # and because a forward is Proxmox-INDEPENDENT — nothing on the hypervisor, which the
  # earlier shared-bridge option was not (the platform is moving off Proxmox). Expose a
  # tenant by setting its `nat_ip` + `edge_port` in terraform/incus var.tenants.

  system.stateVersion = "25.11";
}
