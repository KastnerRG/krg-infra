{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.zfs;

  # Publishes pool health to the node_exporter textfile collector. node_exporter
  # has no native ZFS *pool-health* collector (its zfs collector is ARC/IO stats),
  # so a tiny timer parses `zpool list` into a metric Prometheus can alert on.
  zpoolHealthScript = pkgs.writeShellScript "zpool-health-textfile" ''
    set -uo pipefail
    out="${config.krg.nodeExporter.textfileDir}/zpool.prom"
    tmp="$(${pkgs.coreutils}/bin/mktemp "''${out}.XXXXXX")"
    {
      echo "# HELP zpool_health ZFS pool health (0 = ONLINE, 1 = not ONLINE)"
      echo "# TYPE zpool_health gauge"
      ${config.boot.zfs.package}/sbin/zpool list -H -o name,health 2>/dev/null \
      | while IFS="$(printf '\t')" read -r name health; do
          [ -n "$name" ] || continue
          if [ "$health" = "ONLINE" ]; then val=0; else val=1; fi
          echo "zpool_health{pool=\"$name\",state=\"$health\"} $val"
        done
    } > "$tmp"
    # mktemp creates the temp file 0600. node_exporter runs as the unprivileged
    # `node-exporter` user (not root), so it can't read a 0600 root-owned file —
    # the textfile collector silently skips it (node_textfile_scrape_error=1) and
    # zpool_health never reaches Prometheus. Make it world-readable like the dir's
    # other *.prom files before publishing. (This is why the Pool Health panel was
    # empty on waiter/kastner-ml.)
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$out"
  '';
in {
  options.krg.zfs = {
    enable = mkEnableOption "ZFS filesystem support with auto-scrub and auto-snapshot";

    devNodes = mkOption {
      type = types.str;
      default = "/dev/disk/by-id";
      description = ''
        Directory ZFS scans to import pools. by-id (not by-path/by-uuid, and never
        the kernel sdX/nvmeXn1 names) so imports survive controller/slot/enumeration
        reshuffling — the disko vdevs are declared with by-id paths to match.
      '';
    };

    extraPools = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Pools to import at boot that nothing in `fileSystems` references. The root
        pool is imported because `/` lives on it; a data-only pool whose datasets
        are all mountpoint=none/legacy-but-unmounted would otherwise never be
        imported (e.g. waiter's scratchpool is listed here so its reserved, unmounted
        e4e dataset's pool still imports). List it here.
      '';
    };

    arcMaxBytes = mkOption {
      type = types.nullOr types.ints.unsigned;
      default = null;
      description = ''
        Cap the ZFS ARC (bytes). null = ZFS default (~50% of RAM). On a big-RAM ML
        box this interacts with the OOM killer: ARC counts against /proc/meminfo
        MemAvailable until evicted, so an uncapped ARC + earlyoom can look like
        memory pressure that isn't real. Set a ceiling here if that bites. (See the
        deferred earlyoom base change.)
      '';
    };

    healthTextfile = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Publish per-pool health to the node_exporter textfile collector (a 5-min
        timer writing zpool.prom) so Prometheus/Grafana can alert on a DEGRADED or
        FAULTED pool. Without this, ZFS only emails via ZED (no MTA here) and a
        failed disk goes unnoticed until the weekly scrub. Requires
        krg.nodeExporter (the textfile dir + scrape); on by default with ZFS.
      '';
    };

    autoScrub = mkOption {
      type = types.bool;
      default = true;
    };

    autoScrubInterval = mkOption {
      type = types.str;
      default = "weekly";
    };

    autoSnapshot = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };
      # Retention counts — mirrors snapper-style policy. These enable the global
      # timers; WHICH datasets actually snapshot (and at which cadence) is set
      # per-dataset via the `com.sun:auto-snapshot[:interval]` ZFS properties in
      # disko-config.nix, NOT here:
      #   pool roots default the property to "false" -> opt-in only
      #   persist, tools  -> "true" (all five cadences)
      #   scratch-*       -> "true" but :frequent/:hourly = "false" (daily+ only)
      #   root, nix       -> "false" (root is rolled back; nix is reproducible)
      frequent = mkOption {
        type = types.int;
        default = 4;
        description = "15-minute snapshots to keep";
      };
      hourly = mkOption {
        type = types.int;
        default = 168;
        description = "1 week of hourly snapshots";
      };
      daily = mkOption {
        type = types.int;
        default = 14;
        description = "2 weeks of daily snapshots";
      };
      weekly = mkOption {
        type = types.int;
        default = 16;
        description = "4 months of weekly snapshots";
      };
      monthly = mkOption {
        type = types.int;
        default = 12;
        description = "1 year of monthly snapshots";
      };
    };
  };

  config = mkIf cfg.enable {
    boot.supportedFilesystems = ["zfs"];

    boot.zfs = {
      inherit (cfg) devNodes;
      inherit (cfg) extraPools;

      # No encryption on this deployment (physical security in a locked server
      # room was deemed sufficient). Explicitly off so boot never blocks waiting
      # for a passphrase that doesn't exist. Replaces the old placeholder
      # hardware-config's `requestEncryptionCredentials = true`.
      requestEncryptionCredentials = false;

      # DELIBERATE, ties to networking.hostId (pinned + committed in
      # hosts/waiter/default.nix). With force-import OFF, the pool only imports
      # when the running hostId matches the one that last had it — the interlock
      # that makes the pinned hostId meaningful (prevents two hosts importing the
      # same pool). disko cleanly `zpool export`s at the end of install, so first
      # boot imports fine.
      #
      # GOTCHA — hostId lockout. If networking.hostId ever CHANGES and the pool
      # wasn't cleanly exported (e.g. power loss), the root pool will NOT import
      # and the box won't boot. Recovery is a rescue/installer environment +
      # `zpool import -f nvmepool`. Treat the committed hostId as load-bearing:
      # don't edit it casually, and never reuse it on a second machine.
      forceImportRoot = false;
      forceImportAll = false;
    };

    # ARC ceiling (only when set; null leaves the ZFS default).
    boot.kernelParams = mkIf (cfg.arcMaxBytes != null) [
      "zfs.zfs_arc_max=${toString cfg.arcMaxBytes}"
    ];

    services.zfs.autoScrub = {
      enable = cfg.autoScrub;
      interval = cfg.autoScrubInterval;
    };

    services.zfs.autoSnapshot = {
      enable = cfg.autoSnapshot.enable;
      frequent = cfg.autoSnapshot.frequent;
      hourly = cfg.autoSnapshot.hourly;
      daily = cfg.autoSnapshot.daily;
      weekly = cfg.autoSnapshot.weekly;
      monthly = cfg.autoSnapshot.monthly;
    };

    # Periodic TRIM (weekly). nvmepool also runs continuous autotrim=on (set in
    # disko); periodic is the catch-all sweep. No-op on scratchpool's spinning HDDs
    # (it trims only the NVMe special/cache members).
    services.zfs.trim.enable = true;

    # Pool health → Prometheus (textfile collector). Guarded on node-exporter
    # being on (it owns textfileDir); base.nix enables it on every host.
    systemd.services.zpool-health-textfile = mkIf (cfg.healthTextfile && config.krg.nodeExporter.enable) {
      description = "Write ZFS pool health to the node_exporter textfile dir";
      after = ["zfs-import.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = zpoolHealthScript;
      };
    };
    systemd.timers.zpool-health-textfile = mkIf (cfg.healthTextfile && config.krg.nodeExporter.enable) {
      description = "Periodic ZFS pool-health metric refresh";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Unit = "zpool-health-textfile.service";
      };
    };
  };
}
