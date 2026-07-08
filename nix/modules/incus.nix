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
  pkgs,
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

  # The fleet OpenBao CA (public trust anchor, committed at nix/keys/krg-pki-ca.pem;
  # same file base.nix puts in the system trust store). Placed as Incus's `server.ca`
  # so krg-nat runs in PKI mode + trusts machine clients whose cert chains to it —
  # e.g. the terraform/incus provider's cert, minted from pki_int/issue/incus-client
  # by deploy-tofu.sh. That removes the per-cert `incus config trust add` drift. Guard
  # on pathExists so a checkout WITHOUT the PEM still evaluates (CA trust is then off,
  # falling back to per-cert trust). Additive: individually-trusted certs (a human's
  # browser cert / the coming OIDC) still work.
  caFile = ../keys/krg-pki-ca.pem;
  haveCa = builtins.pathExists caFile;
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

    tenantIngressPortRange = mkOption {
      type = types.str;
      default = "30000-30999";
      description = ''
        Reserved TCP port range on this host for tenant INGRESS proxy devices (ADR 0017
        §5). terraform/incus gives each exposed tenant an `edge_port` in this range and
        attaches an Incus proxy device (krg-nat's external IP:<edge_port> → the instance's
        inner service). This range is opened in the firewall to tenantIngressSources; only
        ports with a live proxy device actually listen. nftables range syntax (e.g.
        "30000-30999"); empty string disables the rule.
      '';
    };

    tenantIngressSources = mkOption {
      type = types.listOf types.str;
      # The zone edges (krg-prod, e4e-prod in nix/networks/trusted.json) — the only clients
      # of the ingress ports: the public path is edge → instance, never client → instance.
      default = ["137.110.161.106" "137.110.161.107"];
      description = ''
        Source IPs/CIDRs allowed to reach the tenant ingress port range in-guest. Defaults
        to the two zone edges that re-encrypt public traffic to instances; nothing else
        should dial these ports directly.
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
        description = ''
          Authentik OIDC client ID (oidc.client.id). Inert unless issuer is set. Incus is
          a PUBLIC OIDC client (authorization-code flow) — there is NO client secret to
          configure (Incus 7.2 has no oidc.client.secret key; verified on-box), so issuer
          + clientId are the whole config.
        '';
      };
    };

    ui.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Serve the Incus web UI on the API port.";
    };

    metrics = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve the Incus Prometheus metrics endpoint on a DEDICATED listener
          (core.metrics_address) for the fleet Prometheus to scrape. This exposes the
          hypervisor's view of every instance — per-instance + per-project
          CPU/memory/disk/network/filesystem, plus daemon metrics — WITHOUT reaching
          into the NAT'd tenant guests (krg-nat sees them all). Scoped to the monitoring
          host by opening the port via krg.firewall.monitoringPorts.

          The endpoint is served UNAUTHENTICATED (core.metrics_authentication = false):
          the firewall is the boundary, the same model node-exporter uses for :9100.
          Off by default; enabled on krg-nat.
        '';
      };
      port = mkOption {
        type = types.port;
        default = 8444;
        description = ''
          Port for the Incus metrics listener (core.metrics_address). Distinct from the
          API port; opened only to the monitoring host.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.incus = {
      enable = true;
      # Feature Incus (7.2.x), NOT the NixOS default incus-lts (7.0.x). Both are in the
      # SAME pinned nixpkgs. The fleet's incus CLI (krg-deploy, pkgs.incus = 7.2) and the
      # lxc/incus terraform provider target recent Incus API extensions (api_filtering,
      # added after 7.0) — against a 7.0 LTS server they fail: the CLI with "server is
      # missing the required api_filtering API extension", the provider with the
      # misleading "daemon doesn't appear to be started". Matching the server to the
      # fleet's client is the fix.
      package = pkgs.incus;
      ui.enable = cfg.ui.enable;

      # Applied by the incus-preseed service on first start. Minimal on purpose —
      # see the file header: pool + API only, tenancy is terraform's.
      preseed = {
        config =
          {
            "core.https_address" = ":${toString cfg.apiPort}";
          }
          // optionalAttrs haveCa {
            # PKI mode: auto-trust machine clients whose cert chains to server.ca
            # (the fleet CA placed by the incus-server-ca service below). No per-cert
            # trust add for the terraform/incus provider.
            "core.trust_ca_certificates" = "true";
          };
        # OIDC is NOT set here: the preseed only runs on FIRST daemon start, but krg-nat is
        # already provisioned (and the client SECRET can't live in the Nix store anyway).
        # All three oidc.* keys are applied to the running daemon by the incus-oidc-config
        # oneshot below (idempotent, every switch), reading the secret from the vault-agent
        # render.

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

    # TENANT INGRESS (ADR 0017 §5): a zone edge reaches a tenant instance through an Incus
    # PROXY DEVICE — a real listening socket on this host (bind=host) that forwards to the
    # instance, declared per exposed tenant in terraform/incus. (An incus_network_forward,
    # tried first, does NOT work here: its prerouting DNAT only fires for host-LOCAL traffic,
    # so external edges saw the port filtered with no conntrack — validated on-box. A proxy
    # device is INPUT-governed like any socket, so it just needs the port opened.) Open the
    # reserved ingress range to the edges only. Bound to krg-nat's external IP in terraform
    # (not 0.0.0.0), so instances can't reach each other's ingress ports across the trusted
    # bridge; this firewall rule is the source gate. Only ports with a live proxy device
    # actually listen — the rest of the range simply has nothing behind it.
    networking.firewall.extraInputRules = mkIf (cfg.tenantIngressPortRange != "") ''
      ip saddr { ${concatStringsSep ", " cfg.tenantIngressSources} } tcp dport ${cfg.tenantIngressPortRange} accept
    '';

    # The Incus unix socket is gated to the `incus-admin` group. Put the break-glass
    # admin (the platform host's operator) in it so `incus …` works without sudo. Human
    # admins reach the API via OIDC/mTLS; this is local-socket management on the box.
    users.users.${config.krg.adminAccount}.extraGroups = ["incus-admin"];

    # Install the fleet CA as Incus's server.ca BEFORE the daemon starts, so PKI mode
    # (core.trust_ca_certificates above) can trust fleet-signed machine clients. Copied
    # each start (idempotent) so a CA rotation is picked up on the next incus restart.
    # Only when the CA PEM is present in the checkout.
    systemd.services.incus-server-ca = mkIf haveCa {
      description = "Install the fleet CA as the Incus server CA (PKI client trust)";
      # Run at ACTIVATION/boot, ordered before incus — NOT only wantedBy incus.service:
      # a deploy that doesn't restart incus.service would then never trigger this, so
      # server.ca stayed missing and CA-client-trust was silently inert (the bug that
      # made the terraform/incus provider fail to authenticate). multi-user.target pulls
      # it in on every switch; before/wantedBy incus.service keeps the ordering.
      wantedBy = ["multi-user.target" "incus.service"];
      before = ["incus.service"];
      restartTriggers = [caFile];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/install -Dm0644 ${caFile} /var/lib/incus/server.ca";
      };
    };

    # Incus reads server.ca ONLY at daemon start (PKI mode), so it must RESTART when the
    # CA lands or rotates — else a daemon that came up before server.ca existed never
    # picks up client-CA trust. Triggering on caFile restarts incus exactly when needed.
    systemd.services.incus.restartTriggers = [caFile];

    # Human OIDC auth (ADR 0017 / 0013): apply oidc.issuer + oidc.client.id to the RUNNING
    # daemon. NOT via preseed — preseed only runs on first daemon start (krg-nat is already
    # provisioned). `incus config set` (key=value form) over the local unix socket
    # (root → admin) is idempotent and applies live. Inert unless oidc.issuer is set.
    #
    # PUBLIC CLIENT — NO client secret. Incus 7.2 has no oidc.client.secret key (verified
    # on-box: setting it → "unknown key"); Incus's OIDC is a public authorization-code
    # client, so issuer + clientId are the whole config. This is AUTHENTICATION only — it
    # sets NO authorizer (Incus 7.2 has no group→admin mapping: `incus auth` doesn't exist,
    # and the scriptlet authorizer can't see OIDC groups). WHO may authenticate is gated at
    # Authentik (the incus app → Domain Admins); WHAT an authenticated user can do is Incus's
    # default, to be settled by an on-daemon spike before any fine-grained authz lands.
    systemd.services.incus-oidc-config = mkIf (cfg.oidc.issuer != "") {
      description = "Apply Incus OIDC config to the running daemon";
      after = ["incus.service"];
      requires = ["incus.service"];
      wantedBy = ["multi-user.target"];
      restartTriggers = [cfg.oidc.issuer cfg.oidc.clientId];
      # incus CLI resolves a config dir under $HOME at startup; give it an ephemeral one.
      environment.HOME = "/run/incus-oidc-config";
      path = [config.virtualisation.incus.package pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "incus-oidc-config";
      };
      script = ''
        set -euo pipefail
        incus config set oidc.issuer=${escapeShellArg cfg.oidc.issuer}
        incus config set oidc.client.id=${escapeShellArg cfg.oidc.clientId}
      '';
    };

    # Prometheus metrics endpoint (ADR 0017 observability). Applied to the RUNNING daemon
    # — NOT via preseed (preseed only runs on first daemon start; krg-nat is already
    # provisioned, same reason as incus-oidc-config above). `incus config set` over the
    # local root→admin socket is idempotent and applies live. Serves /1.0/metrics on a
    # dedicated listener; auth is OFF (the firewall gates it to the monitoring host,
    # node-exporter's model), so this MUST stay paired with the monitoringPorts rule below.
    systemd.services.incus-metrics-config = mkIf cfg.metrics.enable {
      description = "Apply Incus metrics-endpoint config to the running daemon";
      after = ["incus.service"];
      requires = ["incus.service"];
      wantedBy = ["multi-user.target"];
      restartTriggers = [(toString cfg.metrics.port)];
      environment.HOME = "/run/incus-metrics-config";
      path = [config.virtualisation.incus.package pkgs.coreutils];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "incus-metrics-config";
      };
      script = ''
        set -euo pipefail
        incus config set core.metrics_address=${escapeShellArg ":${toString cfg.metrics.port}"}
        incus config set core.metrics_authentication=false
      '';
    };

    # Open the metrics port to the fleet monitoring host only (via monitoringSourceIp),
    # the same firewall path node-exporter uses. Load-bearing: the endpoint is
    # unauthenticated, so the firewall is its ONLY access control.
    krg.firewall.monitoringPorts = mkIf cfg.metrics.enable [cfg.metrics.port];
  };
}
