# Server profile: web services, monitoring, reverse proxy (krg-prod, e4e-prod).
# Import this in a host's default.nix, then add host-specific compose stacks.
{ config, lib, ... }: {
  imports = [
    ./base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/services/compose-stack.nix
    ../modules/services/ipmi-exporter.nix
    ../users/admin.nix
    # Human users come from Samba AD; only the local break-glass admin stays.
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
    serviceHost = true;   # restrict in-guest SSH to trusted UCSD nets
  };

  krg.docker = {
    enable = true;
  };

  # krg.nodeExporter.enable is set by base.nix (true on every host).
  #
  # IPMI exporter only on PHYSICAL hosts. The current server hosts (krg-prod,
  # e4e-prod) are Proxmox VMs with no BMC, so the exporter would just error with
  # nothing to read — and 9290 isn't opened to the scraper here anyway. RESTORE:
  # this auto-enables if a physical server-profile host is ever added (then also
  # add 9290 to monitoringPorts below). The hypervisors' real BMCs are monitored
  # by the Ansible `monitoring` role, not from inside a guest.
  krg.ipmiExporter.enable = lib.mkDefault (!config.krg.base.isVM);

  # Qualys + Trellix are enabled for all machines in base.nix.
  # Provide the installer archive in the host config:
  #   krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  # Ingress for the server role. The in-guest firewall is ON on every host
  # (base.nix); serviceHost = true (set in krg.base above) source-restricts SSH
  # to the trusted UCSD nets in-guest, and the Proxmox perimeter restricts the rest.
  krg.firewall = {
    # 80/443 open globally (Traefik ingress); SSH (22) is source-restricted
    # (serviceHost), so the firewall module moves it from the open list to a
    # per-source rule. Traefik's 8080 (API/metrics) is intentionally NOT published
    # to the host (docker-compose/krg-prod/compose.yml). When Prometheus is
    # re-enabled it will scrape traefik:8080 over the Docker network instead of
    # the host port (add prometheus to traefik_proxy at that time).
    allowedTCPPorts = [ 22 80 443 ];
    # Native node-exporter (9100), scraped from the monitoring host only. (The old
    # 9000 "service exporter" was the Ansible deploy-monitor, gone under autoUpgrade.)
    monitoringPorts = [ 9100 ];
  };
}
