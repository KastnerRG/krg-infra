# Directory-services profile: Samba Active Directory domain controller (LDAP/Kerberos/DNS).
# Import this in a host's default.nix, then add host-specific networking.
{...}: {
  imports = [
    ./server.nix # base + monitored-infra (node-exporter); krg.users + break-glass admin come via base
    ../modules/samba-ad.nix
  ];

  krg.base = {
    enable = true;
    autoUpgrade = true;
    serviceHost = true; # restrict in-guest SSH to trusted UCSD nets
  };

  # Ingress for the directory role. The in-guest firewall is ON (base.nix runs it
  # on every host); modules/samba-ad.nix contributes the AD DC port set as
  # sourcedPorts (sealab + machines + ops — stricter than the fleet CrowdSec
  # default since these protocols are infrastructure-internal). SSH (22) is in
  # base.nix's default allowedTCPPorts; serviceHost=true routes it through
  # sshSources (ucsd + ops). The Proxmox perimeter (ansible proxmox_firewall →
  # 100.fw) is the additive outer layer.
  # node-exporter's 9100 is opened to the monitoring host automatically by
  # nix/modules/services/node-exporter.nix (issue #234); samba-ad.nix contributes
  # the AD DC ports as sourcedPorts. No per-profile krg.firewall block needed here.

  # AD domain controller role for KRG. Realm/workgroup match the new forest;
  # see the "One-time provisioning" notes in modules/samba-ad.nix before deploy.
  krg.sambaAD = {
    enable = true;
    realm = "KRG.LOCAL";
    workgroup = "KRG";
  };

  # Time authority for the domain. In AD the DC is the clock every member follows;
  # this host was serving NOTHING on udp/123, so e4e-nas — which DSM's AD join
  # correctly pointed here for time — failed every sync and free-ran to +40s.
  # `domainTimeSource = null` overrides base.nix's fleet default (mkDefault): the
  # authority takes its time from the public pool upstream, never from itself.
  # modules/time.nix opens udp/123 in-guest via sourcedUDPPorts; the Proxmox
  # perimeter needs the matching rule in
  # ansible/roles/proxmox_firewall/files/krg-ldap.fw — an in-guest allow on its own
  # is dropped at the outer layer before it ever reaches the guest.
  krg.time = {
    server.enable = true;
    domainTimeSource = null;
  };

  # base.nix already makes every host an AD client (Domain Admins, keys-from-AD).
  # This host IS the DC, so flag it: SSSD must not rotate the DC's own machine
  # account or push DNS, and the samba-ad module owns /etc/krb5.conf here. The DC
  # gets its keytab from `samba-tool domain exportkeytab`, not a join.
  krg.adClient.isDomainController = true;
}
