# Laptop profile: the MOBILITY tier — a portable end-user machine. Builds on
# workstation and overrides the two settings that genuinely differ between a
# stationary desktop and something you carry:
#
#   1. sshd OFF by default. SECURE-BY-DEFAULT, and load-bearing: sealab is
#      flat-public (no NAT — see profiles/server.nix), so a laptop on coffee-shop
#      or hotel wifi with a listening sshd is a directly internet-reachable attack
#      surface — exactly the exposure that drove this whole rebuild. A portable
#      machine doesn't listen unless a specific host deliberately re-enables it.
#   2. Suspend ALLOWED. base.nix refuses sleep fleet-wide (servers/VMs/compute must
#      never suspend); a laptop must suspend on lid-close, so we re-allow it here.
#
# mkForce on both because base.nix sets the opposite as a plain (non-mkDefault)
# value; a specific laptop host can still override again on top.
#
# STUB: posture deltas only for now. Power management (TLP / thermald), Wi-Fi +
# roaming (NetworkManager), and any laptop-specific LUKS/MDM tightening land with
# the workstation buildout follow-up. e4e-laptop-01 (or similar) will be the first
# host to import this.
{lib, ...}: {
  imports = [
    ./workstation.nix
  ];

  # Portable machines do not run an internet-reachable sshd by default.
  services.openssh.enable = lib.mkForce false;

  # Re-allow suspend (base.nix forbids it fleet-wide for always-on hosts).
  systemd.sleep.settings.Sleep = {
    AllowSuspend = lib.mkForce true;
    AllowHibernation = lib.mkForce true;
    AllowHybridSleep = lib.mkForce true;
    AllowSuspendThenHibernate = lib.mkForce true;
  };

  # Networking: a laptop is DHCP by default and intentionally sets NO static IP.
  # That's already the effective default — NixOS defaults networking.useDHCP = true
  # and no profile (base/server/laptop) sets an address; static IPs are a per-HOST
  # opt-out (the servers, with their fixed public sealab IPs). The buildout adds
  # NetworkManager, which then OWNS DHCP + Wi-Fi + per-network roaming — so we
  # deliberately don't assert a redundant useDHCP here.
  #
  # TODO(workstation buildout, follow-up PR):
  #   * networking.networkmanager (Wi-Fi + roaming + DHCP)
  #   * services.tlp / thermald (battery + thermal management)
  #   * laptop-specific LUKS / MDM tightening
}
