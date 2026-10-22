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
      # config apply on deploy. Per-service granularity: reloadOnChange (below) detects a
      # retargeted bind-mount symlink per service and recreates only those, so a stack
      # on reloadOnChange doesn't need this (the two are mutually exclusive).
      recreateOnConfigChange = mkOption {
        type = types.bool;
        default = false;
      };

      # Apply a changed stack WITHOUT taking it down (ADR 0024 P1). By default a change
      # to this unit (a compose file, an env line) makes `nixos-rebuild switch` RESTART
      # it, and ExecStop is `compose down`: every service in the stack goes down and
      # comes back, for any one-line change. With this on, the switch RELOADS instead,
      # and ExecReload is compose-reload (compose-stack/compose-reload.py): services
      # labelled `krg.rollout: handoff` get a graceful handoff (new container healthy
      # before the old one stops), and every other CHANGED service is recreated in place
      # by `up -d` exactly as before; unchanged services are not touched at all. A
      # handoff whose new container never turns healthy is rolled back and fails the
      # reload, leaving the old container serving.
      #
      # Off by default: turning it on changes how an already-running stack is updated,
      # so it is enabled per stack, pilot first. Incompatible with recreateOnConfigChange
      # (whole-stack --force-recreate is the opposite of a per-service handoff).
      reloadOnChange = mkOption {
        type = types.bool;
        default = false;
      };

      # compose-reload's bounds for one handoff: how long a new container may take to
      # turn healthy (and an old one to drain), and the pause between draining and
      # stopping the old container so in-flight requests finish.
      handoffTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 180;
      };
      handoffDrainSec = mkOption {
        type = types.ints.unsigned;
        default = 5;
      };

      # Units that must be ACTIVE for this stack to start, without `requires`'
      # restart propagation. systemd restarts a unit whenever a unit it `requires` is
      # restarted, so `requires = ["openbao-agent.service"]` turns every agent re-render
      # (deploy-nixos.sh after each switch, the cert-renewal timer) into a full stack
      # `down`/`up`. Listing the unit here instead orders the stack after it and fails
      # the stack's START closed if it isn't active (no stale/missing secrets), but a
      # later restart of it leaves the running stack alone.
      #
      # CONSEQUENCE: a re-render no longer restarts the stack as a side effect, so any
      # render whose consumer holds the value in memory must set its vaultAgent
      # `reloadCommand` (most already do; check before switching a stack over).
      failClosedOn = mkOption {
        type = types.listOf types.str;
        default = [];
      };
    };
  };

  # compose-reload as stdlib-only Python, packaged like the scratch tools (scratch.nix):
  # writePython3Bin gives a build-time syntax + import check; flakeIgnore drops the
  # style-only lints the repo-wide ruff gate (ruff.toml) already covers.
  composeReload =
    pkgs.writers.writePython3Bin "compose-reload" {
      libraries = [];
      flakeIgnore = ["E203" "E501" "E226" "W503" "W504"];
    }
    (builtins.readFile ./compose-stack/compose-reload.py);

  # ExecStartPre for failClosedOn: refuse to start unless every listed unit is active.
  failClosedCheck = name: units:
    pkgs.writeShellScript "fail-closed-${name}" (concatMapStringsSep "\n" (u: ''
        if ! ${config.systemd.package}/bin/systemctl is-active --quiet ${escapeShellArg u}; then
          echo "${name}: ${u} is not active; refusing to start (fail closed)" >&2
          exit 1
        fi
      '')
      units);

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
    assertions =
      mapAttrsToList (name: stack: {
        assertion = !(stack.reloadOnChange && stack.recreateOnConfigChange);
        message = "krg.composeStacks.${name}: reloadOnChange and recreateOnConfigChange are mutually exclusive (a per-service handoff vs a whole-stack --force-recreate).";
      })
      cfg;

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
          # BOUND the restart loop. `up -d` re-pulls every not-yet-present image on
          # each run, so a stack that can't come up (e.g. a throttled registry pull)
          # would otherwise restart forever every RestartSec and re-pull the whole
          # batch each time — a self-inflicted runaway that exhausted Docker Hub's
          # anonymous pull limit and took krg-prod's deploy red (deploy 29298397434).
          # systemd's DEFAULT start-limiter (5 starts / 10s) never trips here because
          # RestartSec (30s) spaces restarts wider than the 10s window. Widen the
          # window so it actually gives up: at most `startLimitBurst` starts per
          # `startLimitIntervalSec`, then the unit stays `failed` (surfaced to the
          # operator) instead of hammering the registry. `systemctl reset-failed
          # <stack>` (or the next deploy) clears it. A transient blip still rides out
          # within the burst; a persistent failure stops fast.
          startLimitIntervalSec = 3600;
          startLimitBurst = 5;
          # `after` orders us behind network-online.target; `wants` is what actually
          # pulls that target into the boot transaction. Without the wants, systemd
          # warns ("ordered after network-online.target but doesn't depend on it")
          # and the ordering is a no-op — the target may never activate.
          wants = ["network-online.target"] ++ stack.failClosedOn;
          after =
            ["docker.service" "network-online.target"]
            ++ map (n: "docker-network-${n}.service") stack.networks
            ++ stack.after
            ++ stack.failClosedOn;
          requires =
            ["docker.service"]
            ++ map (n: "docker-network-${n}.service") stack.networks
            ++ stack.requires;
          wantedBy = ["multi-user.target"];
          # reloadOnChange: a changed unit is RELOADED on switch (compose-reload), not
          # restarted (compose down + up). See the option.
          restartIfChanged = !stack.reloadOnChange;
          reloadIfChanged = stack.reloadOnChange;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            WorkingDirectory = stack.workingDirectory;
            ExecStartPre = mkIf (stack.failClosedOn != []) "${failClosedCheck name stack.failClosedOn}";
            ExecStart = "${composeCmd stack} up -d --remove-orphans${optionalString stack.recreateOnConfigChange " --force-recreate"}";
            ExecStop = "${composeCmd stack} down";
            # reloadOnChange stacks do NOT `pull` on reload: images change only when the
            # committed compose file changes (a floating tag must not silently move on an
            # unrelated reload). `up` still pulls any image that's missing.
            # --state: per-service resolved bind-mount sources, so a config change that
            # only retargets an L+ symlink (invisible to compose's hash, #458) still
            # recreates/hands off exactly the services that mount it.
            ExecReload =
              if stack.reloadOnChange
              then "${composeReload}/bin/compose-reload --timeout ${toString stack.handoffTimeoutSec} --drain ${toString stack.handoffDrainSec} --state ${stack.workingDirectory}/.compose-reload-state.json -- ${composeCmd stack}"
              else
                pkgs.writeShellScript "reload-${name}" ''
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
