{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.ipmiLan;
in {
  options.krg.ipmiLan = {
    enable = mkEnableOption "declarative BMC LAN (IPMI) network config, enforced in-band via ipmitool";

    channel = mkOption {
      type = types.int;
      default = 1;
      description = "IPMI LAN channel the BMC NIC lives on (usually 1; some boards use 8).";
    };

    address = mkOption {
      type = types.str;
      example = "172.19.161.11";
      description = "Static IPv4 address to enforce on the BMC.";
    };

    netmask = mkOption {
      type = types.str;
      default = "255.255.255.0";
      description = "Subnet mask to enforce on the BMC.";
    };

    gateway = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Default gateway to enforce on the BMC. null leaves the BMC's gateway untouched (correct when the management VLAN is flat / scraped from the same subnet).";
    };
  };

  config = mkIf cfg.enable {
    # Same in-band kernel device as the exporter (ipmi-exporter.nix); declared
    # here too so BMC LAN config works on a host that manages its IP but does
    # not run the exporter.
    boot.kernelModules = ["ipmi_devintf" "ipmi_si"];

    # IaC-strict: the BMC's LAN config is declared here, not hand-set in the BMC
    # web UI. This runs as root (so it can open the 0600 root:root /dev/ipmi0
    # directly — no group needed, unlike the non-root exporter) and is
    # idempotent: it reads current state and only writes on drift, so after the
    # first apply every nixos-rebuild is a no-op set of reads.
    systemd.services.krg-ipmi-lan = {
      description = "Enforce declarative BMC LAN config (in-band)";
      after = ["systemd-modules-load.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.ipmitool];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ch=${toString cfg.channel}

        # The in-band device may appear slightly after the modules load.
        for _ in $(seq 1 30); do [ -e /dev/ipmi0 ] && break; sleep 1; done
        if [ ! -e /dev/ipmi0 ]; then
          echo "krg-ipmi-lan: /dev/ipmi0 absent — no in-band BMC, skipping" >&2
          exit 0
        fi

        # Exact-key lookup from `ipmitool lan print` (labels contain spaces, and
        # "IP Address" is a prefix of "IP Address Source", so match the whole key).
        get() {
          ipmitool lan print "$ch" 2>/dev/null | awk -F: -v k="$1" '
            { key=$1; gsub(/^[ \t]+|[ \t]+$/,"",key);
              if (key==k) { v=$2; for(i=3;i<=NF;i++) v=v":"$i;
                gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit } }'
        }

        [ "$(get "IP Address Source")" = "Static Address" ] || ipmitool lan set "$ch" ipsrc static
        [ "$(get "IP Address")"  = "${cfg.address}" ] || ipmitool lan set "$ch" ipaddr ${cfg.address}
        [ "$(get "Subnet Mask")" = "${cfg.netmask}" ] || ipmitool lan set "$ch" netmask ${cfg.netmask}
        ${optionalString (cfg.gateway != null) ''
          [ "$(get "Default Gateway IP")" = "${cfg.gateway}" ] || ipmitool lan set "$ch" defgw ipaddr ${cfg.gateway}
        ''}
      '';
    };
  };
}
