{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall;
in {
  options.krg.firewall = {
    enable = mkEnableOption "KRG firewall (replaces UFW)";

    allowedTCPPorts = mkOption {
      type    = types.listOf types.port;
      default = [ 22 ];
    };

    allowedUDPPorts = mkOption {
      type    = types.listOf types.port;
      default = [];
    };

    # Ports only reachable from the KRG Prometheus scraping host
    # (krg-prod; set via monitoringSourceIp below, sourced from trusted.json).
    monitoringPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = "Ports open only to monitoringSourceIp (Prometheus scraping)";
    };

    monitoringSourceIp = mkOption {
      type    = types.str;
      # Fallback only — base.nix sets this on every host from trusted.json's
      # monitoring_host (currently krg-prod). Kept in sync to avoid a stale value.
      default = "137.110.161.106";
    };

    allowRDP = mkOption {
      type        = types.bool;
      default     = false;
      description = "Open port 3389 for XRDP (waiter compute nodes)";
    };

    rdpSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        When allowRDP is set: if non-empty, 3389 is reachable ONLY from these
        CIDRs/IPs (source-restricted in-guest); if empty, 3389 is opened globally.
        On a public-IP compute box you want this set — base.nix defaults it to the
        trusted UCSD nets so RDP is never exposed to the whole internet (RDP is not
        key-only and there's no xrdp fail2ban jail). Inert unless allowRDP = true.
      '';
    };

    sshSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        If non-empty, SSH (port 22) is reachable ONLY from these CIDRs/IPs
        in-guest, instead of being globally open. Service hosts set this (mirrors
        the Proxmox perimeter); compute hosts leave it empty (public SSH,
        protected by key-only auth + fail2ban). Usually set via krg.base.serviceHost.
      '';
    };

    sourcedPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      description = ''
        Ports reachable ONLY from specific source CIDRs/IPs in-guest.
        Use for services that should be internal-only (e.g. OpenBao API on
        sealab nets) while still benefiting from in-guest defense-in-depth.
        Each entry: { port = <N>; sources = [ "cidr1" "cidr2" ... ]; }
      '';
    };
  };

  config = mkMerge [
    # krg.firewall is the single switch for the OS firewall. Enabling it turns
    # on nftables + the rules below; disabling it (e.g. VMs where the hypervisor
    # owns the firewall) explicitly turns the NixOS firewall OFF rather than
    # letting it fall back to its restrictive enabled-by-default state.
    { networking.firewall.enable = cfg.enable; }

    (mkIf cfg.enable {
      # extraInputRules uses nftables syntax; enable the nftables backend
      networking.nftables.enable = true;

      networking.firewall = {
        # When sshSources is set, SSH (22) is source-restricted via the rules
        # below, so drop it from the globally-open port list.
        # 3389 only joins the globally-open list when allowRDP is set AND no
        # rdpSources are given; with rdpSources it's source-restricted below.
        allowedTCPPorts =
          (if cfg.sshSources == []
           then cfg.allowedTCPPorts
           else filter (p: p != 22) cfg.allowedTCPPorts)
          ++ optional (cfg.allowRDP && cfg.rdpSources == []) 3389;
        allowedUDPPorts = cfg.allowedUDPPorts;

        # nftables rules: monitoring-port scraping (from monitoringSourceIp),
        # source-restricted SSH (from sshSources, service hosts), and
        # source-restricted RDP (from rdpSources when allowRDP).
        extraInputRules =
          concatMapStringsSep "\n" (port: ''
            ip saddr ${cfg.monitoringSourceIp} tcp dport ${toString port} accept
          '') cfg.monitoringPorts
          + concatMapStringsSep "\n" (src: ''
            ip saddr ${src} tcp dport 22 accept
          '') cfg.sshSources
          + optionalString cfg.allowRDP (concatMapStringsSep "\n" (src: ''
            ip saddr ${src} tcp dport 3389 accept
          '') cfg.rdpSources)
          + concatMapStringsSep "\n" ({ port, sources }: concatMapStringsSep "\n" (src: ''
            ip saddr ${src} tcp dport ${toString port} accept
          '') sources) cfg.sourcedPorts;
      };
    })
  ];
}
