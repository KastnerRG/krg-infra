{...}: {
  imports = [
    ../../profiles/directory.nix
    ./hardware-configuration.nix
  ];

  # Baseline admin account for this machine (krg-admin is the default).
  krg.adminAccount = "krg-admin";

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix runs it on every
  # host) — isVM just enables the QEMU guest agent. Defense-in-depth: the AD DC
  # ports are restricted in-guest (samba-ad module) AND at the Proxmox perimeter
  # (ansible 100.fw); the hypervisor layer is additive, not a replacement.
  krg.base.isVM = true;

  networking = {
    hostName = "krg-ldap";
    useDHCP = false;
    interfaces.ens18.ipv4.addresses = [
      {
        address = "137.110.161.109";
        prefixLength = 24;
      }
    ];
    defaultGateway = "137.110.161.1";
    # Resolver is owned by modules/samba-ad.nix: it force-sets nameservers to
    # 127.0.0.1 (the DC's own internal DNS) with an upstream fallback, so any
    # value here would be overridden.
  };

  # This host is the KRG AD domain controller (role comes from profiles/directory.nix).
  # The domain is NOT created by Nix — after the first deploy, run the one-time
  # `samba-tool domain provision` documented in modules/samba-ad.nix, then start
  # the samba-ad-dc service.

  system.stateVersion = "25.11";
}
