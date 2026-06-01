# Samba Active Directory Domain Controller (AD DC).
#
# This module provisions the *runtime* for an AD DC, but NOT the domain itself:
# `samba-tool domain provision` is a one-time, stateful step that creates the
# AD databases under /var/lib/samba and writes /etc/samba/smb.conf. It cannot be
# expressed purely in Nix (it generates secrets and a SAM database), so it stays
# a manual on-box action. This module makes the box ready for it and runs the
# daemon afterwards. See the "One-time provisioning" section at the bottom.
#
# Design notes:
#   * Uses pkgs.samba4Full — the AD-DC-capable Samba build (LDAP + MDNS + AD DC).
#   * Runs the single combined `samba` daemon (NOT smbd/nmbd/winbindd). We do
#     deliberately NOT enable services.samba, so Nix never owns /etc/samba/smb.conf;
#     the provisioner creates it and it lives on as runtime state.
#   * Frees UDP/TCP 53 for Samba's internal DNS by disabling systemd-resolved and
#     pointing the resolver at the DC itself (127.0.0.1) with an upstream fallback.
#   * krb5.conf is deterministic from the realm, so we render it declaratively.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.sambaAD;

  # nixpkgs' samba derivation (servers/samba/4.x.nix) builds samba-tool's
  # PYTHONPATH from `pythonPath = [ dnspython markdown tdb ]` — it omits the
  # Python `cryptography` module. Samba 4.21+ imports it eagerly (samba.gkdi →
  # Group Key Distribution / gMSA), which `samba-tool domain provision` pulls in
  # via samba.provision → samba.join, so provisioning dies at import with
  # `ModuleNotFoundError: No module named 'cryptography'`. Add it back to
  # pythonPath; wrapPython then resolves cryptography's transitive closure too.
  # This forces a from-source samba rebuild (no binary-cache hit for the override).
  sambaAdDc = pkgs.samba4Full.overrideAttrs (old: {
    pythonPath = (old.pythonPath or [ ]) ++ [ pkgs.python3Packages.cryptography ];
  });
in {
  options.krg.sambaAD = {
    enable = mkEnableOption "Samba Active Directory domain controller";

    package = mkOption {
      type        = types.package;
      default     = sambaAdDc;
      defaultText = literalExpression "pkgs.samba4Full (+ python3Packages.cryptography on pythonPath)";
      description = "Samba package — must be AD-DC-capable (samba4Full).";
    };

    realm = mkOption {
      type        = types.str;
      default     = "KRG.LOCAL";
      description = "Kerberos/AD realm (uppercase DNS domain), e.g. KRG.LOCAL.";
    };

    workgroup = mkOption {
      type        = types.str;
      default     = "KRG";
      description = "NetBIOS domain (short) name, e.g. KRG.";
    };

    dnsBackend = mkOption {
      type        = types.enum [ "SAMBA_INTERNAL" "BIND9_DLZ" ];
      default     = "SAMBA_INTERNAL";
      description = "DNS backend passed to `samba-tool domain provision`.";
    };

    dnsForwarder = mkOption {
      type        = types.str;
      default     = "1.1.1.1";
      description = ''
        Upstream resolver the DC forwards non-AD DNS queries to. Set this as
        `dns forwarder = …` in smb.conf after provisioning (provision does not
        take a forwarder flag).
      '';
    };

    dnsFallback = mkOption {
      type        = types.listOf types.str;
      default     = [ "1.1.1.1" ];
      description = ''
        Secondary resolvers placed in /etc/resolv.conf after 127.0.0.1. This
        keeps the box online before the domain is provisioned (when 127.0.0.1:53
        refuses connections, glibc falls through to these). Once the DC's DNS is
        stable and authoritative you can drop this to [].
      '';
    };

    openFirewall = mkOption {
      type        = types.bool;
      default     = true;
      description = "Open the AD DC well-known ports via krg.firewall.";
    };

    openDynamicRpc = mkOption {
      type        = types.bool;
      default     = true;
      description = ''
        Open the dynamic RPC high-port range (49152-65535). Required for domain
        join, MMC/RSAT management, and DC replication (DRSUAPI). Disable only if
        the perimeter (Proxmox/campus) firewall already restricts these.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = cfg.dnsBackend == "SAMBA_INTERNAL";
      message   = "krg.sambaAD: only SAMBA_INTERNAL is wired up so far; BIND9_DLZ needs a BIND9 + DLZ module first.";
    }];

    # samba-tool, samba, smbclient, wbinfo, ldbsearch on the operator's PATH.
    # krb5 adds the Kerberos client tools (kinit/klist/kdestroy) — Samba ships
    # none, and the post-provision validation (kinit administrator@KRG.LOCAL,
    # see below) needs them. It reads the /etc/krb5.conf rendered above.
    environment.systemPackages = [ cfg.package pkgs.krb5 ];

    # Samba's internal DNS must own port 53 — get systemd-resolved out of the way
    # and resolve through the DC itself (with an upstream fallback pre-provision).
    services.resolved.enable = mkForce false;
    networking.nameservers    = mkForce ([ "127.0.0.1" ] ++ cfg.dnsFallback);
    networking.search         = [ (toLower cfg.realm) ];

    # Deterministic Kerberos config (matches what provision would generate).
    environment.etc."krb5.conf".text = ''
      [libdefaults]
          default_realm = ${cfg.realm}
          dns_lookup_realm = false
          dns_lookup_kdc = true
    '';

    # Parents the provisioner writes into; provision creates the rest.
    systemd.tmpfiles.rules = [
      "d /etc/samba 0755 root root -"
      "d /var/lib/samba 0755 root root -"
    ];

    # The combined AD DC daemon. Stays inactive (ConditionPathExists) until the
    # domain has been provisioned, so it never crash-loops on a fresh box.
    systemd.services.samba-ad-dc = {
      description   = "Samba Active Directory Domain Controller";
      documentation = [ "man:samba(8)" "https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller" ];
      after         = [ "network-online.target" ];
      wants         = [ "network-online.target" ];
      wantedBy      = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/var/lib/samba/private/sam.ldb";
      serviceConfig = {
        Type             = "notify";
        NotifyAccess     = "all";
        ExecStart        = "${cfg.package}/sbin/samba --foreground --no-process-group";
        ExecReload       = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart          = "on-failure";
        RestartSec       = "5s";
        LimitNOFILE      = 16384;
        RuntimeDirectory = "samba";
        TimeoutStartSec  = "60s";
      };
    };

    # AD DC well-known ports. These concatenate with the host's other
    # krg.firewall port declarations (NixOS merges listOf options).
    # CROSS-REFERENCE: the Proxmox perimeter source-restricts this same port set
    # in ansible/roles/proxmox_firewall/files/krg-ldap.fw (VMID 100) — keep aligned.
    krg.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [
        53    # DNS
        88    # Kerberos
        135   # RPC endpoint mapper
        139   # NetBIOS session
        389   # LDAP
        445   # SMB
        464   # kpasswd
        636   # LDAPS
        3268  # Global Catalog
        3269  # Global Catalog over SSL
      ];
      allowedUDPPorts = [
        53    # DNS
        88    # Kerberos
        137   # NetBIOS name service
        138   # NetBIOS datagram
        389   # LDAP / CLDAP
        464   # kpasswd
      ];
    };

    # Dynamic RPC range — listOf port can't express a 16k-port range, so set it
    # straight on networking.firewall (the value merges with the krg.firewall one).
    networking.firewall.allowedTCPPortRanges =
      mkIf (cfg.openFirewall && cfg.openDynamicRpc) [ { from = 49152; to = 65535; } ];
  };

  # ── One-time provisioning (run on the box, after the first deploy) ──────────
  #
  # 1. Provision the new forest (KRG.LOCAL / KRG). Pick a strong admin password:
  #
  #      sudo samba-tool domain provision \
  #        --server-role=dc \
  #        --use-rfc2307 \
  #        --dns-backend=SAMBA_INTERNAL \
  #        --realm=KRG.LOCAL \
  #        --domain=KRG \
  #        --adminpass='<StrongPassword>'
  #
  #    This creates /var/lib/samba/* and /etc/samba/smb.conf. (It refuses to run
  #    if /etc/samba/smb.conf already exists — move it aside if re-provisioning.)
  #
  # 2. Set the upstream forwarder under [global] in /etc/samba/smb.conf:
  #      dns forwarder = 1.1.1.1
  #
  # 3. Start the daemon (the unit's ConditionPathExists now passes):
  #      sudo systemctl start samba-ad-dc
  #
  # 4. Verify:
  #      samba-tool domain level show
  #      host -t SRV _ldap._tcp.krg.local 127.0.0.1
  #      host -t A krg-ldap.krg.local 127.0.0.1
  #      smbclient -L localhost -U%
  #      kinit administrator@KRG.LOCAL    # then: klist
}
