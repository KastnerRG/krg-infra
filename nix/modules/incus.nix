# krg.incus — the Incus platform host (ADR 0017 phase-1 substrate).
#
# This module owns the SUBSTRATE only: "this host runs the Incus daemon and exposes
# its API." It deliberately does NOT declare projects, the tenant NAT network,
# profiles, instances, or quotas — those are the IaC *boundary*, owned by
# `terraform/incus/` and reconciled by `tofu plan` exactly as terraform/openbao
# reconciles OpenBao (ADR 0017 §3, the provision-vs-manage split). nix stands the
# daemon up; tofu shapes tenancy on top. The seam is intentional: it's what makes
# "git is truth" hold on the boundary side (ADR 0001) and keeps adding a tenant a
# terraform change, not a host rebuild.
#
# WHAT THE PRESEED BOOTSTRAPS: the API listen address, the web UI, an Authentik
# OIDC config (optional, for human CLI/UI auth), and a single host-local storage
# pool so the daemon is usable and terraform has somewhere to put instance disks.
# Incus always ships a `default` profile; terraform fills its devices and creates
# the managed NAT network. So nix needs only the pool here.
#
# ISOLATION (ADR 0017 §4): untrusted/self-serve tenants get a full Incus VM (separate
# kernel), not a container — VM-type instances need /dev/kvm inside this guest, which
# requires NESTED VIRTUALIZATION on the fabricant Proxmox VM (cpu host + nested=1).
# That's a hypervisor-side (operator) gate validated at bring-up; there's nothing to
# assert at eval time, but the host won't be able to launch VM instances without it.
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.krg.incus;
  trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
  # API reachable from UCSD institutional + explicit off-campus admin (ops) only.
  # ADR 0017 execution note: the Incus control plane is "UCSD-only" exactly like
  # Proxmox today, and on the current flat-public sealab ([[sealab-flat-public-no-nat]])
  # this firewall rule IS the perimeter until the managed NAT lands. The API is
  # NEVER in publicPorts — OIDC→Authentik gates *who*, this gates *from where*.
  defaultApiSources =
    map (e: e.cidr) (trusted.ipsets.ucsd ++ (trusted.ipsets.ops or []));
in {
  options.krg.incus = {
    enable = mkEnableOption "KRG Incus platform host (ADR 0017)";

    apiPort = mkOption {
      type = types.port;
      default = 8443;
      description = "Incus HTTPS API/UI port (core.https_address).";
    };

    apiSources = mkOption {
      type = types.listOf types.str;
      default = defaultApiSources;
      description = ''
        CIDRs/IPs allowed to reach the Incus API in-guest (lands in
        krg.firewall.sourcedPorts). Defaults to ucsd + ops. The control plane is
        never globally public (ADR 0017 — "source-restrict the Incus API").
      '';
    };

    storage = {
      poolName = mkOption {
        type = types.str;
        default = "default";
        description = "Name of the bootstrap storage pool the preseed creates.";
      };
      driver = mkOption {
        type = types.enum ["dir" "btrfs" "lvm" "zfs"];
        default = "dir";
        description = ''
          Storage backend for the bootstrap pool. Phase-1 default is `dir`: instance
          volumes are files on the durable /var/lib/incus dataset. Deliberately NOT
          a nested zpool — ZFS-on-ZFS is rejected by ADR 0004 (the double ARC / write
          penalty). Phase-2 (bare metal) switches to a real `zfs` pool on its own
          disks.
        '';
      };
    };

    trustedBridges = mkOption {
      type = types.listOf types.str;
      default = ["incusbr0"];
      description = ''
        Incus managed-network bridge interface names to mark trusted in the host
        firewall (networking.firewall.trustedInterfaces). REQUIRED for the internal
        NAT to work: Incus runs dnsmasq on each managed bridge to answer instances'
        DHCP + DNS, but those requests arrive at the host on the bridge and
        krg.firewall's default-drop INPUT would eat them before dnsmasq sees them —
        so instances get NO IPv4 lease (eth0 up, 0 packets received). Trusting the
        bridge accepts that INPUT; egress then works via Incus's own NAT/FORWARD
        rules (NixOS doesn't filter FORWARD by default).

        Names MUST match the networks terraform/incus creates (its
        `nat_network_name`, default "incusbr0"). Add each managed bridge here; a
        network whose bridge isn't listed will have dead instance networking.
      '';
    };

    oidc = {
      issuer = mkOption {
        type = types.str;
        default = "";
        description = ''
          Authentik OIDC issuer URL for Incus API/UI auth (oidc.issuer). Empty = OIDC
          unconfigured (TLS client-cert admin only, which is how terraform/incus
          authenticates anyway). Wired in a later PR alongside the terraform/authentik
          provider; when set, also set clientId.
        '';
      };
      clientId = mkOption {
        type = types.str;
        default = "";
        description = "Authentik OIDC client ID (oidc.client.id). Inert unless issuer is set.";
      };
    };

    ui.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Serve the Incus web UI on the API port.";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;
      ui.enable = cfg.ui.enable;

      # Applied by the incus-preseed service on first start. Minimal on purpose —
      # see the file header: pool + API only, tenancy is terraform's.
      preseed = {
        config =
          {
            "core.https_address" = ":${toString cfg.apiPort}";
          }
          // optionalAttrs (cfg.oidc.issuer != "") {
            "oidc.issuer" = cfg.oidc.issuer;
            "oidc.client.id" = cfg.oidc.clientId;
          };

        # ONE host-local pool so the daemon is usable and terraform has a place for
        # instance disks. The NAT network, projects, profiles, instances and quotas
        # are NOT here — terraform/incus owns them (ADR 0017 §3).
        storage_pools = [
          {
            name = cfg.storage.poolName;
            driver = cfg.storage.driver;
          }
        ];
      };
    };

    # The Incus API listens on all interfaces (core.https_address = :PORT); the
    # in-guest firewall is what scopes it to ucsd+ops. sourcedPorts is STRICTER than
    # the fleet CrowdSec floor and always wins over the globally-open list.
    krg.firewall.sourcedPorts = [
      {
        port = cfg.apiPort;
        sources = cfg.apiSources;
      }
    ];

    # Egress SNAT for the managed NAT network needs IP forwarding. Incus enables this
    # for its bridge, but pin it so a sysctl default can't silently break tenant
    # egress.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # NFTABLES COEXISTENCE (resolved). krg.firewall sets networking.nftables.enable
    # with a default-drop INPUT chain; Incus's managed-network firewall driver installs
    # its OWN nftables table for NAT/FORWARD. Those coexist (separate tables), BUT the
    # instances' DHCP/DNS to Incus's dnsmasq arrives at the HOST on the bridge and hits
    # krg.firewall's INPUT drop first — so without this, instances get eth0 up but no
    # IPv4 lease (0 packets received). Trusting the managed bridge(s) accepts that INPUT;
    # egress works via Incus's NAT (NixOS doesn't filter FORWARD by default). Verified
    # on krg-nat: with the bridge trusted, a test instance gets a 10.x lease + egress.
    networking.firewall.trustedInterfaces = cfg.trustedBridges;
  };
}
