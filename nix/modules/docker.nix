{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.docker;
in {
  imports = [ ./ad-group-sync.nix ];

  options.krg.docker = {
    enable = mkEnableOption "KRG Docker CE configuration";

    # AD groups bridged into the local `docker` group so their members can use the
    # Docker daemon. This mirrors krg.nvidia.cudaAccessGroups: SSSD algorithmic ID
    # mapping derives an AD group's GID from its SID, so a new AD group can never BE
    # the local `docker` group; instead a boot+timer unit (the shared
    # modules/ad-group-sync.nix) re-derives the local docker group's members from
    # these AD groups (getent → gpasswd -M). Login (krg.adClient.allowedGroups) gates
    # who may SSH in; this gates who may use Docker.
    accessGroups = mkOption {
      type    = types.listOf types.str;
      default = [];
      example = [ "Docker Users" ];
      description = ''
        AD groups whose members are bridged into the local `docker` group (Docker
        daemon access). Matched by name via getent (so the group must resolve through
        SSSD). Empty = no AD group gets Docker (only members the flake puts in `docker`
        directly, e.g. the local break-glass admin via defaultGroups). NOTE: docker
        group membership is effectively root on the host — scope the AD group tightly.
      '';
    };

    enableNvidiaRuntime = mkOption {
      type        = types.bool;
      default     = false;
      description = "Register nvidia-container-runtime in the Docker daemon (for GPU nodes)";
    };

    metricsAddr = mkOption {
      type    = types.str;
      default = "0.0.0.0:9323";
    };

    defaultPublishAddress = mkOption {
      type    = types.str;
      default = "127.0.0.1";
      description = ''
        Default host address Docker binds published container ports to when a
        compose/`-p` mapping doesn't specify one (Docker's daemon `ip` setting).

        Defaults to loopback so a bare `- "PORT:PORT"` is NOT exposed on the host's
        external interface. This is the fleet-wide backstop for the fact that Docker
        DNATs published ports through the FORWARD path, BYPASSING krg.firewall
        (nftables INPUT) — so the host firewall alone cannot keep a published port
        off the network. Ports that must be reachable remotely opt in explicitly
        with `0.0.0.0:` (e.g. Traefik 80/443) or a specific host IP.

        Also tightens ad-hoc `docker run -p X:Y` on compute boxes to loopback —
        expose over the network with `-p 0.0.0.0:X:Y` or an SSH tunnel. Set to
        "0.0.0.0" to restore Docker's stock behaviour (publish on all interfaces).

        CAVEAT: this only controls the BIND ADDRESS. A port deliberately bound to
        0.0.0.0 (dcgm 9400, scraped remotely) still bypasses krg.firewall's
        source restriction — that needs a DOCKER-USER/nftables FORWARD rule
        (CLAUDE.md pending item).
      '';
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker = {
      enable      = true;
      enableOnBoot = true;

      daemon.settings = mkMerge [
        {
          "metrics-addr" = cfg.metricsAddr;
          # Bind unspecified published ports to loopback by default (see option doc):
          # the in-guest firewall can't govern Docker's DNAT'd ports, so keep them
          # off the external interface unless a compose file explicitly opts in.
          "ip" = cfg.defaultPublishAddress;
          builder.gc = {
            enabled            = true;
            defaultKeepStorage = "512GB";
            policy             = [{ keepStorage = "0"; filter = [ "unused-for=2160h" ]; }];
          };
        }
        (mkIf cfg.enableNvidiaRuntime {
          runtimes.nvidia = {
            path = "${pkgs.nvidia-container-toolkit}/bin/nvidia-container-runtime";
            args = [];
          };
        })
        # TODO (planned, not yet): ship container logs to a central Loki FLEET-WIDE
        # (every machine, probably from base.nix). The old approach here — Docker's
        # loki log-driver via an on-first-boot `docker plugin install` — was removed
        # for now: it's fragile (a dead Loki endpoint can hang docker) and isn't the
        # path we want for the fleet roll-out.
      ];
    };

    # Bridge the accessGroups AD groups into the local docker group (Docker daemon
    # access). The boot+timer sync engine + its fail-safe/union semantics live in the
    # shared modules/ad-group-sync.nix (imported above); this just wires this module's
    # public option into it, producing the `docker-group-sync` unit. (After a switch
    # there's a <=10min window until the timer re-syncs; run `systemctl start
    # docker-group-sync` to apply immediately.)
    krg.adGroupSync.docker.adGroups = cfg.accessGroups;
  };
}
