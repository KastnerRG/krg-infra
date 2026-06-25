# Server profile: the "always-on, monitored, never-roaming lab host" tier.
#
# It sits BETWEEN base (anything that runs the KRG baseline — including a roaming
# laptop) and the role leaves (directory / services / compute). The ONLY thing it
# adds over base is the monitored-infra delta: the Prometheus node-exporter scrape
# surface, wired to the monitoring host.
#
# WHY THE SECURITY POSTURE IS *NOT* HERE: perimeter hardening (deny-inbound
# firewall, CrowdSec + bouncer, SSH source-restriction, key-only sshd) deliberately
# lives in base.nix, not this tier. The sealab network is flat-public — every host
# has a directly internet-reachable IP, no NAT — so a public-facing workstation
# needs that baseline just as much as a server does. Hardening is universal; this
# tier is the monitoring/role delta only. Revisit the split if NAT/segmentation
# ever lands (then a NAT'd endpoint could legitimately relax inbound).
#
# Consumers: directory.nix, services.nix, compute.nix, and the plain server VMs
# (krg-vault, krg-deploy) import this instead of base.nix.
{lib, ...}: let
  trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
in {
  imports = [
    ./base.nix
    ../modules/services/node-exporter.nix
  ];

  # Prometheus node exporter on every monitored host (native systemd service). It
  # opens its scrape port (9100) only to monitoringSourceIp (node-exporter.nix), so
  # no per-host firewall entry is needed. A host that runs node_exporter another way
  # can override this with mkForce.
  krg.nodeExporter.enable = lib.mkDefault true;

  # Prometheus scrape source — from the shared trusted-networks file so the
  # monitoring host isn't duplicated across nix / ansible / PVE.
  krg.firewall.monitoringSourceIp = lib.mkDefault trusted.monitoring_host;
}
