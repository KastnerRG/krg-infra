# Workstation profile: a lab END-USER endpoint (stationary desktop) running the
# KRG baseline — AD login, OEC, the hardened public-facing firewall posture, an
# sshd you remote into, and no-suspend (a desktop is plugged in and always
# available). It is a SIBLING of server, not a child: it gets base's full hardened
# baseline (correct — sealab is flat-public, see profiles/server.nix) but NOT the
# monitored-infra delta (node-exporter), because an end-user desktop isn't a
# Prometheus scrape target.
#
# The mobility tier (profiles/laptop.nix) builds on this and overrides the two
# settings that differ for a portable machine: it turns the sshd listener OFF and
# re-allows suspend.
#
# STUB: this is currently the structural anchor only. The real desktop buildout —
# local desktop environment (GNOME/KDE), LUKS full-disk encryption (the headline
# endpoint requirement, ADR 0012), printing, etc. — lands in a follow-up PR. No
# host imports this yet.
{...}: {
  imports = [
    ./base.nix
  ];

  # Inherits from base.nix as-is for now:
  #   * sshd ON (you remote into a desktop) — base sets services.openssh.enable
  #   * no-suspend (a desktop stays available) — base sets systemd.sleep.* false
  #   * the hardened public-facing firewall + CrowdSec + AD baseline
  #
  # TODO(workstation buildout, follow-up PR):
  #   * desktop environment (services.xserver / GNOME or KDE)
  #   * LUKS FDE (boot.initrd.luks) — ADR 0012 endpoint device management
  #   * krg.localCache-style dev ergonomics if these become dev boxes
}
