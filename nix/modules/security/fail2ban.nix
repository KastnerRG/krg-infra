{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.fail2ban;
in {
  options.krg.fail2ban = {
    enable = mkEnableOption "KRG fail2ban SSH protection";

    bantime = mkOption {
      type = types.str;
      default = "1d";
    };

    bantimeIncrement = mkOption {
      type = types.bool;
      default = true;
      description = "Exponentially increase ban duration for repeat offenders";
    };

    bantimeRndtime = mkOption {
      type = types.int;
      default = 3600;
      description = "Random time added to ban (seconds), prevents coordinated timing attacks";
    };

    maxRetry = mkOption {
      type = types.int;
      default = 5;
    };

    ignoreIP = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Never ban these CIDRs/IPs (loopback + trusted admin nets). base.nix
        populates this from nix/networks/trusted.json so an admin can't lock
        themselves out from a trusted network — mirrors the Ansible layer's
        fail2ban_ignoreip (which was the only place this allow-list existed).
      '';
    };
  };

  config = mkIf cfg.enable {
    services.fail2ban = {
      enable = true;
      extraPackages = [pkgs.ipset];
      ignoreIP = cfg.ignoreIP;

      bantime = cfg.bantime;
      bantime-increment = {
        enable = cfg.bantimeIncrement;
        rndtime = "${toString cfg.bantimeRndtime}s";
      };

      jails.sshd.settings = {
        enabled = true;
        filter = "sshd";
        maxretry = cfg.maxRetry;
      };
    };
  };
}
