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

    # Local in-band collection: freeipmi (bundled in the exporter package) opens
    # /dev/ipmi0. Three things blocked that and left every collector reporting
    # `ipmi_up 0` ("could not find inband device"):
    #   1. the kernel IPMI device must exist (load the in-band modules), and
    #   2. it's 0600 root:root by default, but the exporter runs as a non-root
    #      DynamicUser — so give the device an `ipmi` group (0660) and add the
    #      exporter's dynamic user to it (DAC), and
    #   3. the generic prometheus-exporter sandbox hides it: PrivateDevices=true
    #      gives the unit a minimal private /dev, and DevicePolicy=closed blocks
    #      char-239 at the cgroup. Punch just /dev/ipmi0 through both.
    # (This nixpkgs has no hardware.ipmi module, so the udev rule/group are wired
    # here rather than via hardware.ipmi.enable.)
    boot.kernelModules = ["ipmi_devintf" "ipmi_si"];
    users.groups.ipmi = {};
    services.udev.extraRules = ''
      KERNEL=="ipmi[0-9]*", GROUP="ipmi", MODE="0660"
    '';
    systemd.services.prometheus-ipmi-exporter.serviceConfig = {
      SupplementaryGroups = ["ipmi"];
      PrivateDevices = mkForce false;
      DeviceAllow = mkForce ["/dev/ipmi0 rw"];
    };

    # Open the scrape port to the Prometheus host wherever the exporter runs
    # (issue #234) — same fleet-wide auto-wiring as node-exporter.nix, so a host
    # with a BMC is reachable by the scraper without a per-host monitoringPorts
    # entry. VMs don't enable this module (no BMC), so 9290 stays closed there.
    krg.firewall.monitoringPorts = [cfg.port];
  };
}
