# Prometheus node exporter (native systemd via NixOS).
# CROSS-REFERENCE: the Proxmox-host counterpart is ansible/roles/monitoring
# (binary + systemd unit). Keep the port aligned; both feed the same Prometheus.
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.krg.nodeExporter;
in {
  options.krg.nodeExporter = {
    enable = mkEnableOption "Prometheus node exporter (native systemd service)";

    port = mkOption {
      type = types.port;
      default = 9100;
    };

    collectors = mkOption {
      type = types.listOf types.str;
      # systemd: unit states. mdadm: software-RAID array health from /proc/mdstat
      # (covers waiter's 4-way ESP md array — degradation shows up in Prometheus
      # with no extra exporter). textfile: ingests *.prom files from textfileDir,
      # which is how krg.zfs publishes zpool health (node_exporter has no native
      # ZFS pool-health collector). All three are no-ops where they don't apply.
      default = ["systemd" "mdadm" "textfile"];
    };

    textfileDir = mkOption {
      type = types.str;
      default = "/var/lib/node_exporter/textfile";
      description = ''
        Directory the textfile collector scrapes for *.prom files. Other modules
        (e.g. krg.zfs zpool-health) drop metrics here to surface them in Prometheus
        without a dedicated exporter. Created on every host so the collector never
        warns about a missing directory.
      '';
    };
  };

  config = mkIf cfg.enable {
    # World-readable (metrics aren't secret); writers run as root.
    systemd.tmpfiles.rules = ["d ${cfg.textfileDir} 0755 root root -"];

    services.prometheus.exporters.node = {
      enable = true;
      port = cfg.port;
      enabledCollectors = cfg.collectors;
      extraFlags = ["--collector.textfile.directory=${cfg.textfileDir}"];
    };
  };
}
