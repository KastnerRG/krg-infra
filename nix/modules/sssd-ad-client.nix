# SSSD-based Active Directory client: makes a host RESOLVE (NSS) and AUTHORIZE
# (PAM) Samba AD users, so people log in with their KRG.LOCAL accounts instead of
# local users. Pairs with modules/samba-ad.nix (the DC) and is written to be
# reusable on member hosts (waiter, krg-prod) later — not DC-specific.
#
# By default uid/gid are auto-mapped from each user's AD SID (`idMapping = true`,
# SSSD's `ldap_id_mapping`) — deterministic and identical across all SSSD hosts, so
# no per-user uidNumber/gidNumber is ever set. Home dir and shell come from
# fallback_homedir/default_shell. Set `idMapping = false` to instead read RFC2307
# attributes from AD (then every account needs uidNumber/gidNumber/home/shell).
#
# SSH stays KEY-ONLY (the base.nix hardening that closed the breach): SSSD supplies
# identity + the account/session phases (incl. home-dir creation), NOT a password
# prompt. Public keys live in the user's ~/.ssh/authorized_keys (created on first
# login), unless `sshKeysFromAD` is on (served from AD via sss_ssh_authorizedkeys).
#
# Access control uses SSSD's ad_access_filter (memberOf), not sshd AllowGroups,
# because default AD group names contain spaces ("Domain Admins") which AllowGroups
# can't express. Local users (krg-admin) are unaffected: PAM uses pam_sss with
# user_unknown=ignore, and NSS resolves files before sss.
#
# Deploying this BEFORE the runtime prerequisites is safe: sssd is gated on the
# machine keytab (ConditionPathExists=/etc/krb5.keytab), so on a not-yet-joined host
# it is condition-SKIPPED rather than failed — the switch (and its OEC/hardening)
# still succeeds, and local key login keeps working. AD users resolve once the host
# is joined (keytab present) and sssd starts. (sssd genuinely cannot start without a
# keytab — an ungated unit exits non-zero and, under switch-to-configuration-ng,
# fails the whole deploy; see the ConditionPathExists note in config below.)
#
# ── Runtime prerequisites (stateful, NOT expressible in Nix) ────────────────────
# Deploying this module only wires NSS/PAM/sshd; per-host and per-user setup is
# manual and lives in the runbook (kept in one place so it can't drift):
#   * Per host: export a Kerberos keytab to /etc/krb5.keytab (on the DC:
#       `samba-tool domain exportkeytab /etc/krb5.keytab`; on members, a join).
#   * Per user: POSIX attrs (uidNumber/gidNumber/unixHomeDirectory/loginShell),
#       group membership for access, and — when sshKeysFromAD = true — the
#       one-time OpenSSH-LPK schema extension plus the user's sshPublicKey.
#   See ../../docs/creating-a-user.md for the exact commands.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.adClient;
  baseDN = concatMapStringsSep "," (c: "DC=${c}") (splitString "." cfg.domain);
  # memberOf filter for the named groups (default container CN=Users).
  groupFilter =
    optionalString (cfg.allowedGroups != [])
    "(|${concatMapStringsSep "" (g: "(memberOf=CN=${g},CN=Users,${baseDN})") cfg.allowedGroups})";
  effectiveFilter =
    if cfg.accessFilter != null
    then cfg.accessFilter
    else groupFilter;
  # shell_fallback target: null means store-path bash, which (unlike /bin/bash)
  # always exists on NixOS — so a fallback never resolves to a missing path.
  effectiveShellFallback =
    if cfg.shellFallback != null
    then cfg.shellFallback
    else "${pkgs.bashInteractive}/bin/bash";
in {
  options.krg.adClient = {
    enable = mkEnableOption "SSSD Active Directory client (log in as AD users)";

    realm = mkOption {
      type = types.str;
      default = "KRG.LOCAL";
      description = "AD Kerberos realm (uppercase).";
    };

    domain = mkOption {
      type = types.str;
      default = "krg.local";
      description = "AD DNS domain (lowercase).";
    };

    server = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Pin a specific DC as ad_server. Null = DNS SRV autodiscovery.";
    };

    serverIp = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "137.110.161.109";
      description = ''
        IP of `server`, pinned in /etc/hosts so a member host can resolve the DC
        without depending on it for DNS. Also lets this module render a usable
        krb5.conf on hosts that aren't the DC. Null = rely on existing DNS.
      '';
    };

    isDomainController = mkOption {
      type = types.bool;
      default = false;
      description = ''
        This host IS the DC (shares the box with samba-ad). Disables SSSD machine-
        account password rotation + dynamic DNS updates (the DC must not rotate its
        own account), and yields krb5.conf to the samba-ad module. Members leave
        this false so their machine password rotates normally.
      '';
    };

    allowedGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["Domain Admins"];
      description = ''
        Restrict login to members of these AD groups (matched by memberOf under
        CN=Users). Empty = any enabled domain account may log in. Built into
        ad_access_filter, which (unlike sshd AllowGroups) handles names with
        spaces. Groups in a custom OU need the raw `accessFilter` instead.
      '';
    };

    accessFilter = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Raw ad_access_filter; overrides allowedGroups when set.";
    };

    sudoGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["Domain Admins"];
      description = ''
        AD groups whose members get sudo (PASSWORD required — AD users have a
        password, unlike the key-only break-glass admin which is NOPASSWD). Separate
        from allowedGroups: allowedGroups gates who may log IN, sudoGroups gates who
        may escalate. Empty = no AD group gets sudo (only the local break-glass admin).
        Names with spaces (e.g. "Domain Admins") are escaped for sudoers automatically.
      '';
    };

    idMapping = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Auto-assign POSIX uid/gid algorithmically from each user's AD SID
        (ldap_id_mapping) — deterministic and identical across SSSD hosts, so no
        per-user uidNumber/gidNumber is ever set. Set false to read RFC2307
        attributes from AD instead (then every account needs uidNumber, gidNumber,
        unixHomeDirectory and loginShell, or it won't resolve).
      '';
    };

    sshKeysFromAD = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Serve SSH authorized keys from AD via sss_ssh_authorizedkeys (keys stored
        in the sshPublicKey attribute). Requires extending the Samba AD schema with
        that attribute first. When false, keys come from ~/.ssh/authorized_keys.
      '';
    };

    gpoAccessControl = mkOption {
      type = types.enum ["disabled" "permissive" "enforcing"];
      default = "disabled";
      description = ''
        SSSD ad_gpo_access_control. SSSD's default (enforcing) fetches Group Policy
        from sysvol every login; against a Samba AD DC that errors and an error
        under enforcing becomes a denial ("Access denied … System error"). We gate
        access with the memberOf filter (allowedGroups), not GPOs, so default to
        disabled. Use permissive (log only) or enforcing if you adopt GPOs.
      '';
    };

    allowedShells = mkOption {
      type = types.listOf types.str;
      default = ["*"];
      example = ["/run/current-system/sw/bin/bash" "/run/current-system/sw/bin/zsh"];
      description = ''
        SSSD allowed_shells, evaluated per host: a user's AD loginShell is honoured
        only where that exact path is in /etc/shells on THIS host; if it is allowed
        here but not in /etc/shells it is replaced by `shellFallback`; if it is in
        neither, SSSD hands back a nologin shell. The default `[ "*" ]` (wildcard)
        means "any shell in /etc/shells is used, everything else falls back" — so a
        single AD loginShell value is safe across heterogeneous hosts: e.g.
        /run/current-system/sw/bin/zsh resolves to zsh on a zsh-enabled NixOS host
        but degrades to bash on Debian members or NixOS hosts without programs.zsh,
        instead of locking the user out. Set `[ ]` to omit allowed_shells entirely
        (the raw loginShell is then returned verbatim — the pre-fallback behaviour,
        which CAN lock a user out of a host that lacks their shell). Per-user shells
        are set in AD; see ../../docs/creating-a-user.md.
      '';
    };

    shellFallback = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = literalExpression ''"''${pkgs.bashInteractive}/bin/bash"'';
      description = ''
        SSSD shell_fallback: the shell substituted when a user's shell is allowed
        (in `allowedShells`) but not installed (not in /etc/shells). Null = the
        Nix-store bash, which always exists on NixOS (unlike /bin/bash). Only takes
        effect when `allowedShells` is non-empty.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.sssd = {
      enable = true;
      sshAuthorizedKeysIntegration = cfg.sshKeysFromAD;
      config = ''
        [sssd]
        config_file_version = 2
        services = nss, pam${optionalString cfg.sshKeysFromAD ", ssh"}
        domains = ${cfg.realm}

        [nss]
        fallback_homedir = /home/%u
        # NixOS has no /bin/bash — a login shell must be a real path (store bash)
        # or sshd rejects the account pre-auth: "shell /bin/bash does not exist".
        default_shell = ${pkgs.bashInteractive}/bin/bash
        ${optionalString (cfg.allowedShells != []) ''
          # Per-user AD loginShell, fail-safe across heterogeneous hosts. SSSD
          # honours a user's loginShell only where that path is in /etc/shells on
          # THIS host (so /run/current-system/sw/bin/zsh → zsh on a zsh host); a
          # shell allowed here but not installed degrades to shell_fallback rather
          # than nologin, so an AD value that is invalid on this box (a NixOS path
          # on Debian, zsh on a host without programs.zsh) lands on bash instead of
          # locking the user out. "*" = any installed shell. docs/creating-a-user.md.
          allowed_shells = ${concatStringsSep ", " cfg.allowedShells}
          shell_fallback = ${effectiveShellFallback}''}

        [pam]
        ${optionalString cfg.sshKeysFromAD "\n[ssh]\n"}
        [domain/${cfg.realm}]
        id_provider = ad
        auth_provider = ad
        access_provider = ad
        chpass_provider = ad
        # Gate access via the memberOf filter below, not GPOs (GPO fetch errors
        # against Samba AD and would deny everyone with a "System error").
        ad_gpo_access_control = ${cfg.gpoAccessControl}
        ad_domain = ${cfg.domain}
        ${optionalString (cfg.server != null) "ad_server = ${cfg.server}"}
        krb5_realm = ${cfg.realm}
        # uid/gid source: SID-derived id-mapping (automatic) vs RFC2307 attributes.
        ldap_id_mapping = ${
          if cfg.idMapping
          then "True"
          else "False"
        }
        use_fully_qualified_names = false
        cache_credentials = true
        krb5_store_password_if_offline = true
        fallback_homedir = /home/%u
        default_shell = ${pkgs.bashInteractive}/bin/bash
        ${optionalString cfg.isDomainController ''
          # This host IS the DC — never let SSSD rotate its machine-account
          # password or push DNS updates.
          ad_maximum_machine_account_password_age = 0
          dyndns_update = false''}
        ${optionalString cfg.sshKeysFromAD "ldap_user_ssh_public_key = sshPublicKey"}
        ${optionalString (effectiveFilter != "") "ad_access_filter = ${effectiveFilter}"}
      '';
    };

    # sssd CANNOT start without a machine keytab (/etc/krb5.keytab): on a host that is
    # deployed but NOT yet AD-joined it exits non-zero ("Providers did not start in
    # time"), and switch-to-configuration-ng (26.05+) turns that one failed unit into a
    # non-zero SWITCH (exit 4) — failing the whole deploy and, via fail-fast, starving
    # every downstream host of OEC + hardening. That contradicts the intended order:
    # deploy + harden FIRST, JOIN second (docs/joining-a-host-to-the-domain.md). Gate
    # the unit on the keytab so an unjoined host CONDITION-SKIPS sssd (skipped ≠ failed
    # → the switch succeeds and hardening lands); once joined (keytab present) it starts
    # normally, and the join runbook's `systemctl restart sssd` picks it up immediately.
    # A joined host whose keytab went missing is still caught — loudly — by the phase-4
    # `adcli testjoin` gate (read-only, after hardening), not by breaking the switch.
    systemd.services.sssd.unitConfig.ConditionPathExists = "/etc/krb5.keytab";

    # NOTE: key-only AD login depends on sshd's AuthorizedKeysCommand, which upstream's
    # sshAuthorizedKeysIntegration installs as a `#!/bin/sh` wrapper at
    # /etc/ssh/authorized_keys_command. /bin/sh is served by the envfs FUSE mount
    # (services.envfs, oec module), so a wedged envfs daemon would hang every AD login.
    # We do NOT try to bypass it by pointing AuthorizedKeysCommand straight at the
    # sss_ssh_authorizedkeys store binary: sshd rejects that ("Unsafe AuthorizedKeysCommand
    # ... bad ownership or modes for directory /nix/store" — /nix/store is group-writable),
    # so the wrapper-in-/etc is required. The real fix for the hang is the envfs 1.2.0
    # pin (flake.nix / oec module); break-glass krg-admin stays usable regardless (its key
    # comes from /etc/ssh/authorized_keys.d, not this command).

    # Enforce the access filter for key-based SSH: pam_sss runs in the account
    # phase as [default=bad success=ok user_unknown=ignore] — denies non-permitted
    # AD users while leaving local users (krg-admin) to fall through to pam_unix.
    security.pam.services.sshd.sssdStrictAccess = true;

    # SSSD supplies identity, not the home directory — create it on first login.
    security.pam.services.sshd.makeHomeDir = true;
    security.pam.services.login.makeHomeDir = true;
    # The XRDP desktop authenticates through its OWN PAM stack (xrdp-sesman), which
    # does NOT inherit sshd/login's pam_mkhomedir. Without this, an AD user who reaches
    # a box straight through the Guacamole→RDP gateway (never SSH'd in first) has no
    # NFS home; sesman then can't start Xorg (no place for .Xauthority/.xorgxrdp) and
    # the client gets "X server could not be started". Guard the whole attr on
    # services.xrdp.enable so we don't materialise a phantom pam service (and a stray
    # /etc/pam.d/xrdp-sesman) on non-desktop hosts.
    security.pam.services.xrdp-sesman = mkIf config.services.xrdp.enable {makeHomeDir = true;};

    # Sudo for AD admin groups (PASSWORD required — distinct from the key-only
    # break-glass admin's NOPASSWD rule in users/admin.nix). Group names with spaces
    # like "Domain Admins" must be escaped for sudoers (%Domain\ Admins); NixOS's
    # security.sudo.extraRules would NOT escape them, so build the lines here.
    security.sudo.extraConfig = mkIf (cfg.sudoGroups != []) ''
      # krg.adClient.sudoGroups — AD groups granted sudo (password required).
      ${concatMapStringsSep "\n"
        (g: "%${builtins.replaceStrings [" "] ["\\ "] g} ALL=(ALL:ALL) ALL")
        cfg.sudoGroups}
    '';

    # kinit/klist for domain users; adcli for the one-time domain JOIN (and re-join
    # after a rebuild/DR) — without it the documented `adcli join` is "command not found".
    # kstart provides krenew (+ k5start): wrap a long job as `krenew -K 60 -- <job>`
    # and it refreshes the TGT before each 10h expiry, so training/batch runs (and the
    # cifs.upcall ticket for sec=krb5 mounts) survive past one ticket lifetime without a
    # re-`kinit`. Renewability itself comes from renew_lifetime in krb5.conf below.
    # See docs/kerberos-long-jobs.md.
    environment.systemPackages = [pkgs.krb5 pkgs.adcli pkgs.kstart];

    # Resolve the DC without depending on it for DNS (member hosts). On the DC this
    # is its own name→IP, harmless. mkDefault so a host can override.
    networking.hosts =
      mkIf (cfg.server != null && cfg.serverIp != null)
      {${cfg.serverIp} = mkDefault [cfg.server];};

    # Every domain member uses the AD DC as its PRIMARY DNS by default. This is
    # required, not just tidy: SSSD's own (c-ares) resolver queries the servers in
    # resolv.conf directly and does NOT consult the /etc/hosts pin above, so unless
    # the DC is a real nameserver the member cannot resolve krg-ldap.krg.local (the
    # internal krg.local zone) and SSSD flaps offline — which breaks logins for any
    # not-yet-cached (i.e. brand-new) user with a bare "Permission denied (publickey)".
    # The DC runs SAMBA_INTERNAL DNS and forwards non-AD queries upstream
    # (samba-ad.nix dnsForwarder), so it resolves everything; mkBefore keeps it ahead
    # of a host's site fallback resolvers. NOT applied on the DC itself (it owns its
    # resolver via samba-ad.nix) nor when serverIp is null (SRV autodiscovery, which
    # then relies on DNS that already serves krg.local).
    networking.nameservers =
      mkIf (!cfg.isDomainController && cfg.serverIp != null)
      (mkBefore [cfg.serverIp]);

    # krb5.conf for member hosts (the DC's samba-ad module renders its own at normal
    # priority, so mkDefault here yields on the DC and applies on members). KDC is
    # pinned to `server`, resolved via the /etc/hosts entry above.
    environment.etc."krb5.conf".text = mkDefault ''
      [libdefaults]
          default_realm = ${cfg.realm}
          dns_lookup_realm = false
          dns_lookup_kdc = ${
        if cfg.server != null
        then "false"
        else "true"
      }
          rdns = false
          # Renewable tickets for long-running jobs. The 10h ticket lifetime stays
          # (it's the revocation cadence — a leaked ccache dies in 10h), but with
          # renew_lifetime set a plain `kinit` yields a ticket RENEWABLE for 7d, so
          # `krenew -K 60 -- <job>` rolls fresh 10h tickets for a week with no password.
          # The DC's MaxRenewAge already permits 7d (verified); this is the client ask.
          renew_lifetime = 7d
          # Pin the ccache to a deterministic, persistent, per-uid FILE. The kernel's
          # cifs.upcall (sec=krb5 mounts) runs in a bare env and can't see $KRB5CCNAME —
          # it resolves the cache by uid + this setting. Pinning it makes kinit, krenew,
          # and cifs.upcall agree on ONE cache, so a renewed TGT actually reaches the
          # mount's reconnect upcall. FILE in /tmp survives logout (left-running jobs
          # keep auth) and matches krb5's current compiled default — pinned so a future
          # nixpkgs default change (e.g. to KEYRING) can't silently break the chain.
          default_ccache_name = FILE:/tmp/krb5cc_%{uid}
      ${optionalString (cfg.server != null) ''
        [realms]
            ${cfg.realm} = {
                kdc = ${cfg.server}
                admin_server = ${cfg.server}
            }

        [domain_realm]
            .${cfg.domain} = ${cfg.realm}
            ${cfg.domain} = ${cfg.realm}''}
    '';
  };
}
