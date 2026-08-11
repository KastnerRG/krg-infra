# Managed time synchronization (chrony) — with the AD domain controller as the
# fleet's time authority.
#
# WHY THIS EXISTS: nothing in this repo declared time before. Every NixOS host
# silently rode the systemd-timesyncd default (`*.nixos.pool.ntp.org`) and
# fabricant rode Debian's chrony default — undeclared, unauditable, and with no
# coherent domain clock. What surfaced it: DSM's AD join points e4e-nas at the
# domain controller for time (correct AD behavior), but krg-ldap served no NTP at
# all — nothing listening on udp/123, 123 absent from modules/samba-ad.nix's port
# set. So every sync failed ("There is no sys.peer NTP server" / "Failed to sync
# time with krg-ldap.krg.local") and the NAS free-ran to +40s over ~70 days
# (~6.6 ppm — ordinary crystal drift, not a hardware fault). Kerberos tolerates
# 5 minutes of skew, so this degrades silently for a long time before it breaks
# authentication outright — while already corrupting SMB mtimes, security-log
# forensics, and cross-host log correlation.
#
# THE SHAPE (the standard AD time hierarchy):
#
#     public pool  ->  krg-ldap (the DC; krg.time.server.enable)  ->  every member
#
# Members PREFER the DC — one coherent domain clock is what Kerberos and SMB
# timestamps actually care about, more than absolute accuracy — but keep the
# public pool configured as a fallback, so a krg-ldap outage degrades accuracy
# instead of leaving hosts with no time source at all. That fallback is
# deliberate: krg-ldap is a known SPOF (the second-DC work is still pending), and
# time is exactly the wrong thing to make strictly dependent on it.
#
# CROSS-LAYER — three implementations of one policy, keep them aligned:
#   * here (nix)        — every NixOS host, via profiles/base.nix
#   * ansible/roles/base — the Proxmox/Debian hosts (fabricant), same server list
#   * spec/e4e-nas/dsm-system.yml `ntp.server` — DSM, applied by
#     ansible/synology/roles/synology_dsm_system (DSM runs a daily ntpdate, not a
#     daemon; it has no chrony to give it).
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.krg.time;

  # Shared trusted-network data — single source of truth, also consumed by the
  # Ansible layer. Edit nix/networks/trusted.json.
  trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);

  # Same source list modules/samba-ad.nix gates the AD ports on. Time service is
  # part of the same domain surface, so it gets the same audience: every domain
  # member lives in sealab or machines, and ops covers admin remotes.
  # `unique` because those sets overlap (krg-prod and kastner-ml are in both) —
  # duplicate nftables rules are merely redundant, but duplicate chrony `allow`
  # lines are noise in a config an operator has to read during an outage.
  domainSources = unique (map (e: e.cidr) (
    trusted.ipsets.sealab
    ++ trusted.ipsets.machines
    ++ (trusted.ipsets.ops or [])
  ));
in {
  options.krg.time = {
    enable =
      mkEnableOption "managed NTP time synchronization (chrony)"
      // {default = false;};

    servers = mkOption {
      type = types.listOf types.str;
      default = [
        "0.nixos.pool.ntp.org"
        "1.nixos.pool.ntp.org"
        "2.nixos.pool.ntp.org"
        "3.nixos.pool.ntp.org"
      ];
      description = ''
        Upstream NTP servers. These are the same pool hosts the unmanaged
        NixOS default used, but DECLARED — the point of this option is that the
        fleet's time source is now visible in git instead of inherited from a
        distro default. On the DC (`server.enable`) these are the real upstream;
        on members they are the fallback behind `domainTimeSource`.

        Campus note: `time.ucsd.edu` does not resolve, so there is no UCSD-local
        stratum to prefer here; the public pool is the correct choice for a
        lab that needs seconds, not microseconds.
      '';
    };

    domainTimeSource = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "137.110.161.109";
      description = ''
        Address of the AD domain controller to PREFER as the time source, or
        null for none (the DC itself sets this to null — it is the authority,
        it does not chase itself).

        Prefer the IP over the hostname: the DC also runs the domain's DNS
        (SAMBA_INTERNAL), so resolving `krg-ldap.krg.local` to find the time
        server would make time depend on the very host being timed. Same
        reasoning as `krg.nfsHome.server`.

        Configured with chrony's `prefer`, NOT as the only server — if the DC
        is unreachable, chrony falls back to `servers` rather than leaving the
        host with no source.
      '';
    };

    server = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve NTP to the domain (the AD DC role). In AD the domain controller
          is the authoritative clock for every member; without this, members
          configured per AD convention to sync from the DC fail silently and
          free-run — which is exactly what happened to e4e-nas.
        '';
      };

      allowedSources = mkOption {
        type = types.listOf types.str;
        default = domainSources;
        defaultText = literalExpression "sealab + machines + ops CIDRs from nix/networks/trusted.json";
        description = ''
          CIDRs allowed to query this NTP server (chrony `allow`). Defaults to
          the same audience modules/samba-ad.nix gates the AD ports on, so the
          time service and the rest of the domain surface can't drift apart.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Open udp/123 to `allowedSources` via krg.firewall.sourcedUDPPorts.

          REMEMBER THE OTHER LAYER: krg-ldap is a Proxmox guest, so the in-guest
          allow is not sufficient on its own — the perimeter drops the packet
          first. The matching rule lives in
          ansible/roles/proxmox_firewall/files/krg-ldap.fw. Keep them aligned.
        '';
      };

      signedNtp = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve Samba-signed (authenticated) NTP via the `ntp_signd` socket.

          Only Windows domain members need this — w32time demands authenticated
          NTP from the DC by default. Linux and DSM members use plain NTP, which
          is the entire current member set, so this is off.

          NOT WIRED UP: nixpkgs' chrony is not built with `--enable-ntp-signd`,
          so turning this on means switching the DC to ntpsec (or overriding
          chrony) first. The option exists to mark the decision point; it
          asserts rather than silently serving unsigned time to a Windows box
          that will reject it.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.server.signedNtp;
        message = ''
          krg.time.server.signedNtp: not implemented — nixpkgs' chrony lacks
          --enable-ntp-signd. Switch the DC to ntpsec with Samba's
          ntp_signd socket before enabling this (only needed once Windows
          domain members join).
        '';
      }
      {
        assertion = cfg.servers != [] || cfg.domainTimeSource != null;
        message = "krg.time: no time source configured — set krg.time.servers and/or krg.time.domainTimeSource.";
      }
    ];

    # chrony over timesyncd: timesyncd is an SNTP client only — it cannot serve
    # time (needed on the DC) and has no `prefer`/fallback source selection
    # (needed on members). The upstream chrony module already forces timesyncd
    # off, so the fleet converges on one implementation.
    services.chrony = {
      enable = true;

      # Fallback/upstream pool. `serverOption = "iburst"` (module default)
      # applies here; the preferred domain source is emitted below because
      # `prefer` is per-server and this option is not.
      inherit (cfg) servers;

      # makestep defaults (threshold 0.1s, first 3 updates) already step a
      # badly-off clock at boot and slew afterwards — the correct behavior for
      # a host that has been free-running. Not overridden.
      extraConfig = concatStringsSep "\n" (
        optional (cfg.domainTimeSource != null) ''
          # AD domain time authority — preferred so the domain shares one clock
          # (Kerberos/SMB care about agreement with the DC, not absolute
          # accuracy). Falls back to the pool above if unreachable.
          server ${cfg.domainTimeSource} iburst prefer
        ''
        ++ optionals cfg.server.enable (
          [
            ''
              # --- NTP server role (AD domain controller) ---
              # Serve time to domain members. Sources mirror the AD port set in
              # modules/samba-ad.nix; the Proxmox perimeter needs the matching
              # udp/123 rule in ansible/.../files/krg-ldap.fw.
            ''
          ]
          ++ (map (src: "allow ${src}") cfg.server.allowedSources)
          ++ [
            ''

              # Keep serving if upstream is unreachable. A domain whose members
              # agree with a slightly-wrong DC still authenticates; a domain
              # whose members lose their time source entirely does not. Stratum
              # 10 keeps this well below any real upstream, so members prefer
              # genuine time whenever it is available.
              local stratum 10
            ''
          ]
        )
      );
    };

    # In-guest firewall. The Proxmox perimeter is additive and separate — see
    # `server.openFirewall`.
    krg.firewall = mkIf (cfg.server.enable && cfg.server.openFirewall) {
      sourcedUDPPorts = [
        {
          port = 123; # NTP (domain time authority)
          sources = cfg.server.allowedSources;
        }
      ];
    };
  };
}
