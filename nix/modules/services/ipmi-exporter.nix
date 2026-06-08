{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.krg.ipmiExporter;
in {
  options.krg.ipmiExporter = {
    enable = mkEnableOption "Prometheus IPMI exporter (native systemd service)";

    port = mkOption {
      type = types.port;
      default = 9290;
    };
  };

  # Uses the nixpkgs-provided ipmi_exporter.
  # CROSS-REFERENCE: the Proxmox-host counterpart is ansible/roles/monitoring
  # (manual binary install). Keep versions/ports aligned.
  config = mkIf cfg.enable {
    services.prometheus.exporters.ipmi = {
      enable = true;
      inherit (cfg) port;
    };
  };
}
