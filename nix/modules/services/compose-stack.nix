{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.composeStacks;

  stackOpts = {name, ...}: {
    options = {
      description = mkOption {
        type = types.str;
        default = "${name} Docker Compose stack";
      };

      # Ordered list of compose files.
      # Pass the directory as a Nix path then string-interpolate:
      #   composeFiles = [ "${../../docker-compose/fabricant}/compose.yml" ];
      # This copies the whole directory to the store so that Docker Compose
      # `include:` directives can resolve sibling files from the same path.
      composeFiles = mkOption {
        type = types.listOf types.str;
      };

      # Runtime directory for secrets, data, and config that must live outside
      # the Nix store (e.g. .secrets/, postgres/data/, grafana/).
      # Docker Compose path resolution uses this as the project directory so
      # relative paths in compose files (like ./.secrets/foo.txt) resolve here.
      workingDirectory = mkOption {
        type = types.str;
        default = "/var/lib/krg/${name}";
      };

      envFile = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      after = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      requires = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      # External Docker networks that must exist before this stack starts.
      # A separate oneshot service is created per network.
      networks = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      # Force `docker compose up -d` to recreate containers on converge (issue #458).
      # `up -d` only recreates a service when the compose SPEC changes — but committed
      # config is bind-mounted via a stable project-dir path (a tmpfiles `L+` symlink
      # whose store-path target changes on every edit). Compose can't see that the
      # symlink retargeted, so a container keeps its OLD config until force-recreated —
      # silent config drift on every deploy (it crash-looped a fishsense worker on stale
      # config while the fix "deployed" with no effect).
      #
      # With this on, ExecStart adds `--force-recreate`. The stack unit only re-runs when
      # its content-addressed source tree actually changed, so this recreates on a real
      # change — not on every converge. TRADE-OFF: it recreates the WHOLE stack (a brief
      # restart of every service, stateful ones included), not just the service whose
      # config changed. Off by default (krg-prod's big stateful stack keeps its behavior);
      # nixosModules.tenant turns it ON — repo-owns-deploy tenants MUST have committed
      # config apply on deploy. Per-service granularity = migrate that config to a
      # top-level compose `configs:` (compose content-hashes those), then this is moot.
      recreateOnConfigChange = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  composeCmd = stack: let
    fileFlags = concatStringsSep " " (map (f: "-f ${f}") stack.composeFiles);
    envFlag = optionalString (stack.envFile != null) "--env-file ${stack.envFile}";
  in "${pkgs.docker}/bin/docker compose --project-directory ${stack.workingDirectory} ${fileFlags} ${envFlag}";

  # Unique network names across all stacks
  allNetworks = unique (flatten (mapAttrsToList (_: s: s.networks) cfg));
in {
  options.krg.composeStacks = mkOption {
    type = types.attrsOf (types.submodule stackOpts);
    default = {};
    description = "Docker Compose stacks managed as systemd services";
  };

  config = mkIf (cfg != {}) {
    # Ensure working directories and .secrets/ subdirectories exist
    systemd.tmpfiles.rules = flatten (mapAttrsToList (name: stack: [
        "d ${stack.workingDirectory}         0750 root docker -"
        "d ${stack.workingDirectory}/.secrets 0700 root root   -"
      ])
      cfg);

    systemd.services = mkMerge [
      # One oneshot per external Docker network
      (listToAttrs (map (net:
        nameValuePair "docker-network-${net}" {
          description = "Create Docker network ${net}";
          after = ["docker.service"];
          requires = ["docker.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "create-network-${net}" ''
              ${pkgs.docker}/bin/docker network inspect ${net} >/dev/null 2>&1 \
                || ${pkgs.docker}/bin/docker network create ${net}
            '';
          };
        })
      allNetworks))

      # One service per compose stack
      (mapAttrs (name: stack: {
          inherit (stack) description;
          # `after` orders us behind network-online.target; `wants` is what actually
          # pulls that target into the boot transaction. Without the wants, systemd
          # warns ("ordered after network-online.target but doesn't depend on it")
          # and the ordering is a no-op — the target may never activate.
          wants = ["network-online.target"];
          after =
            ["docker.service" "network-online.target"]
            ++ map (n: "docker-network-${n}.service") stack.networks
            ++ stack.after;
          requires =
            ["docker.service"]
            ++ map (n: "docker-network-${n}.service") stack.networks
            ++ stack.requires;
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            WorkingDirectory = stack.workingDirectory;
            ExecStart = "${composeCmd stack} up -d --remove-orphans${optionalString stack.recreateOnConfigChange " --force-recreate"}";
            ExecStop = "${composeCmd stack} down";
            ExecReload = pkgs.writeShellScript "reload-${name}" ''
              ${composeCmd stack} pull
              ${composeCmd stack} up -d --remove-orphans
            '';
            Restart = "on-failure";
            RestartSec = "30s";
          };
        })
        cfg)
    ];
  };
}
