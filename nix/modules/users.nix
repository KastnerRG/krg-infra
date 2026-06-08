{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.users;

  userOpts = {name, ...}: {
    options = {
      uid = mkOption {
        type = types.nullOr types.int;
        default = null;
      };

      home = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Home directory. null = NixOS default (/home/<name>). Set this to keep an
          account OFF a shared/network /home — e.g. the break-glass admin, which
          must work when the NFS /home server is down (see users/admin.nix and
          modules/nfs-home.nix).
        '';
      };

      description = mkOption {
        type = types.str;
        default = "";
      };

      groups = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      shell = mkOption {
        type = types.str;
        default = "bash";
      };

      authorizedKeys = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "SSH public keys";
      };

      hashedPassword = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      # Individual commands this user may run with sudo NOPASSWD.
      # Set sudoNoPassword = true to grant unrestricted sudo instead.
      sudoAllowCommands = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      sudoNoPassword = mkOption {
        type = types.bool;
        default = false;
      };

      expires = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Account expiry date (YYYY-MM-DD). Informational only in NixOS.";
      };
    };
  };
in {
  options.krg.users = {
    users = mkOption {
      type = types.attrsOf (types.submodule userOpts);
      default = {};
      description = "KRG managed user accounts";
    };

    defaultGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra groups appended to every KRG user's group list";
    };
  };

  config = mkIf (cfg.users != {}) {
    users.users = mapAttrs (name: u:
      {
        isNormalUser = true;
        inherit (u) description;
        extraGroups = u.groups ++ cfg.defaultGroups;
        shell = pkgs.${u.shell} or pkgs.bash;
        openssh.authorizedKeys.keys = u.authorizedKeys;
        inherit (u) hashedPassword;
      }
      // optionalAttrs (u.uid != null) {inherit (u) uid;}
      // optionalAttrs (u.home != null) {
        inherit (u) home;
        createHome = true;
      })
    cfg.users;

    security.sudo.extraRules = flatten (mapAttrsToList (
        name: u:
          optional (u.sudoNoPassword || u.sudoAllowCommands != []) {
            users = [name];
            commands =
              if u.sudoNoPassword
              then [
                {
                  command = "ALL";
                  options = ["NOPASSWD"];
                }
              ]
              else
                map (cmd: {
                  command = cmd;
                  options = ["NOPASSWD"];
                })
                u.sudoAllowCommands;
          }
      )
      cfg.users);
  };
}
