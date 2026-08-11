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
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.sambaAD;

  # nixpkgs' samba derivation (servers/samba/4.x.nix) builds samba-tool's
  # PYTHONPATH from `pythonPath = [ dnspython markdown tdb ]` — it omits the
  # Python `cryptography` module. Samba 4.21+ imports it eagerly (samba.gkdi →
  # Group Key Distribution / gMSA), which `samba-tool domain provision` pulls in
  # via samba.provision → samba.join, so provisioning dies at import with
  # `ModuleNotFoundError: No module named 'cryptography'`. Add it back to
  # pythonPath; wrapPython then resolves cryptography's transitive closure too.
  # This forces a from-source samba rebuild (no binary-cache hit for the override).
  # Drop this override once nixpkgs ships cryptography in samba's pythonPath.
  # Fixed upstream in NixOS/nixpkgs#522031 (master, 2026-06-02) but NOT in
  # nixos-25.11 or nixos-26.05 (missed the 26.05 branch) — needs a 26.05
  # backport or nixos-26.11. Tracking: KastnerRG/krg-infra#173.
  sambaAdDc = pkgs.samba4Full.overrideAttrs (old: {
    pythonPath = (old.pythonPath or []) ++ [pkgs.python3Packages.cryptography];
  });

  # Converge the ONE smb.conf line that is fleet-load-bearing: `dns forwarder`.
  #
  # Nix deliberately does not own /etc/samba/smb.conf (see the header) — the
  # provisioner writes it and it lives on as runtime state. That is fine for the
  # file as a whole, but the forwarder is different in kind: EVERY member host
  # puts this DC first in resolv.conf (modules/sssd-ad-client.nix `mkBefore`), so
  # this single line decides whether the entire fleet can resolve non-AD names.
  # Leaving it to a hand-edit (the old runbook step) is exactly the drift ADR 0001
  # forbids, and it bit us: the live file had `dns forwarder = 1.1.1.1` TWICE
  # (repeated hand-edits) pointing at a public resolver that cannot see the
  # internal-only *.ucsd.edu records, so `krg-vault`/`krg-prod` failed to resolve
  # fleet-wide and Phase 0 of the deploy died on `Could not resolve hostname`.
  #
  # Surgical on purpose: it rewrites ONLY `dns forwarder` lines and leaves every
  # other provisioner-written setting untouched. Runs as ExecStartPre of the DC
  # daemon, which is gated on the domain already being provisioned, so smb.conf
  # exists by then; the guard below keeps it a no-op on an unprovisioned box.
  ensureDnsForwarder = pkgs.writeShellScript "samba-ad-ensure-dns-forwarder" ''
    set -euo pipefail
    conf=/etc/samba/smb.conf
    want=${cfg.dnsForwarder}

    # Pre-provision (or a re-provision in flight): nothing to converge yet.
    [ -f "$conf" ] || exit 0

    count=$(${pkgs.gnugrep}/bin/grep -cE '^[[:space:]]*dns forwarder[[:space:]]*=' "$conf" || true)
    if [ "$count" = "1" ] &&
      ${pkgs.gnugrep}/bin/grep -qE "^[[:space:]]*dns forwarder[[:space:]]*=[[:space:]]*$want[[:space:]]*$" "$conf"; then
      exit 0 # already exactly one correct line — leave the file alone
    fi

    tmp=$(${pkgs.coreutils}/bin/mktemp "$conf.XXXXXX")
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"

    # Drop every existing forwarder line (deduping repeats), then re-insert a
    # single one immediately after the [global] header.
    ${pkgs.gnused}/bin/sed -E '/^[[:space:]]*dns forwarder[[:space:]]*=/d' "$conf" |
      ${pkgs.gawk}/bin/awk -v want="$want" '
        { print }
        !inserted && tolower($0) ~ /^[[:space:]]*\[global\][[:space:]]*$/ {
          print "\tdns forwarder = " want; inserted = 1
        }
        END { exit(inserted ? 0 : 1) }
      ' > "$tmp" || {
      # No [global] section — refuse to install a file the DC would ignore.
      ${pkgs.coreutils}/bin/rm -f "$tmp"
      echo "samba-ad: no [global] section in $conf; refusing to set dns forwarder" >&2
      exit 1
    }

    ${pkgs.coreutils}/bin/mv -f "$tmp" "$conf"
    echo "samba-ad: converged 'dns forwarder = $want' in $conf (was $count line(s))"
  '';
in {
  options.krg.sambaAD = {
    enable = mkEnableOption "Samba Active Directory domain controller";

    package = mkOption {
      type = types.package;
      default = sambaAdDc;
      defaultText = literalExpression "pkgs.samba4Full (+ python3Packages.cryptography on pythonPath)";
      description = "Samba package — must be AD-DC-capable (samba4Full).";
    };

    realm = mkOption {
      type = types.str;
      default = "KRG.LOCAL";
      description = "Kerberos/AD realm (uppercase DNS domain), e.g. KRG.LOCAL.";
    };

    workgroup = mkOption {
      type = types.str;
      default = "KRG";
      description = "NetBIOS domain (short) name, e.g. KRG.";
    };

    dnsBackend = mkOption {
      type = types.enum ["SAMBA_INTERNAL" "BIND9_DLZ"];
      default = "SAMBA_INTERNAL";
      description = "DNS backend passed to `samba-tool domain provision`.";
    };

    dnsForwarder = mkOption {
      type = types.str;
      default = "132.239.0.252";
      description = ''
        Upstream resolver the DC forwards non-AD DNS queries to, converged into
        `dns forwarder = …` under [global] in smb.conf (provision does not take a
        forwarder flag, so the daemon's ExecStartPre enforces it — see below).

        MUST be the CAMPUS resolver, not a public one. `*.ucsd.edu` is
        SPLIT-HORIZON: the newer fleet records (krg-ldap, krg-deploy, krg-vault,
        krg-prod) exist ONLY in campus DNS, while the older ones (waiter,
        fabricant, e4e-nas, kastner-ml) are also published publicly. A public
        forwarder therefore resolves *part* of the fleet and returns NODATA for
        the rest — which is far worse than an outright outage, because it looks
        like flaky DNS rather than a misconfiguration.
      '';
    };

    dnsFallback = mkOption {
      type = types.listOf types.str;
      default = ["132.239.0.252"];
      description = ''
        Secondary resolvers placed in /etc/resolv.conf after 127.0.0.1. This
        keeps the box online before the domain is provisioned (when 127.0.0.1:53
        refuses connections, glibc falls through to these). Once the DC's DNS is
        stable and authoritative you can drop this to [].

        Campus DNS for the same split-horizon reason as `dnsForwarder`: a public
        fallback cannot see the internal-only fleet records.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the AD DC well-known ports via krg.firewall.";
    };

    openDynamicRpc = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open the dynamic RPC high-port range (49152-65535). Required for domain
        join, MMC/RSAT management, and DC replication (DRSUAPI). Disable only if
        the perimeter (Proxmox/campus) firewall already restricts these.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dnsBackend == "SAMBA_INTERNAL";
        message = "krg.sambaAD: only SAMBA_INTERNAL is wired up so far; BIND9_DLZ needs a BIND9 + DLZ module first.";
      }
    ];

    # samba-tool, samba, smbclient, wbinfo, ldbsearch on the operator's PATH.
    # krb5 adds the Kerberos client tools (kinit/klist/kdestroy) — Samba ships
    # none, and the post-provision validation (kinit administrator@KRG.LOCAL,
    # see below) needs them. It reads the /etc/krb5.conf rendered above.
    # python3: the AD-IaC apply (ansible/krg-ad/, ADR 0010) runs apply_ad.py ON
    # the DC, and ansible needs a target interpreter; samba-tool's own python is
    # wrapped and not exposed as a general `python3` on PATH, so add it.
    environment.systemPackages = [cfg.package pkgs.krb5 pkgs.python3];

    # Samba's internal DNS must own port 53 — get systemd-resolved out of the way
    # and resolve through the DC itself (with an upstream fallback pre-provision).
    services.resolved.enable = mkForce false;
    networking.nameservers = mkForce (["127.0.0.1"] ++ cfg.dnsFallback);
    networking.search = [(toLower cfg.realm)];

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
      description = "Samba Active Directory Domain Controller";
      documentation = ["man:samba(8)" "https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      unitConfig.ConditionPathExists = "/var/lib/samba/private/sam.ldb";
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # Converge `dns forwarder` before the daemon reads smb.conf. Because the
        # store path embeds the value, changing krg.sambaAD.dnsForwarder changes
        # the unit — so a rebuild restarts the DC and re-applies it, rather than
        # leaving the new value stranded until the next manual restart.
        ExecStartPre = "${ensureDnsForwarder}";
        ExecStart = "${cfg.package}/sbin/samba --foreground --no-process-group";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 16384;
        RuntimeDirectory = "samba";
        TimeoutStartSec = "60s";
      };
    };

    # AD DC well-known ports. Source-restricted to sealab + machines + ops
    # in-guest as STRICTER defense-in-depth than the fleet-default US+trusted
    # geoIP gate (issue #74). AD clients are infrastructure-internal — they
    # never legitimately connect from outside our trusted nets, and the
    # Proxmox perimeter already restricts this same port set in
    # ansible/roles/proxmox_firewall/files/krg-ldap.fw (VMID 100) — these
    # in-guest rules mirror that perimeter so a misconfigured PVE rule can't
    # silently widen exposure to US+trusted via the geoIP default.
    # Trusted IPSets are read here from the shared trusted.json (same
    # source-of-truth as the Proxmox layer); ops is included so an admin
    # joining their workstation to the AD doesn't need a Proxmox-side
    # exception.
    krg.firewall = mkIf cfg.openFirewall (let
      trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
      adSources = map (e: e.cidr) (
        trusted.ipsets.sealab
        ++ trusted.ipsets.machines
        ++ (trusted.ipsets.ops or [])
      );
      mk = port: {
        inherit port;
        sources = adSources;
      };
    in {
      sourcedPorts = map mk [
        53 # DNS
        88 # Kerberos
        135 # RPC endpoint mapper
        139 # NetBIOS session
        389 # LDAP
        445 # SMB
        464 # kpasswd
        636 # LDAPS
        3268 # Global Catalog
        3269 # Global Catalog over SSL
      ];
      sourcedUDPPorts = map mk [
        53 # DNS
        88 # Kerberos
        137 # NetBIOS name service
        138 # NetBIOS datagram
        389 # LDAP / CLDAP
        464 # kpasswd
        # NTP (udp/123) is deliberately NOT here — it belongs to the time
        # authority role, not the Samba daemon, so modules/time.nix opens it
        # (same trusted.json sources) when krg.time.server.enable is set. It was
        # missing from BOTH for a long time, which is why e4e-nas — correctly
        # pointed at this DC by its AD join — failed every sync and free-ran.
      ];
    });

    # Dynamic RPC range (TCP 49152-65535): source-restrict via raw nftables
    # to match the well-known ports above. krg.firewall.sourcedPorts doesn't
    # express ranges (listOf port can't); emit the rule directly here.
    # CROSS-REFERENCE: ansible/roles/proxmox_firewall/files/krg-ldap.fw —
    # keep these source lists aligned. Inert unless openDynamicRpc is set.
    networking.firewall.extraInputRules = mkIf (cfg.openFirewall && cfg.openDynamicRpc) (let
      trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
      adSources = map (e: e.cidr) (
        trusted.ipsets.sealab
        ++ trusted.ipsets.machines
        ++ (trusted.ipsets.ops or [])
      );
      # Split by family — same colon-detection krg.firewall uses. If
      # trusted.json grows v6 entries later, this stays correct (a
      # hardcoded `ip saddr` against a v6 address would silently
      # produce invalid nftables and drop the v6 restriction).
      isV6 = src: lib.hasInfix ":" src;
      v4 = lib.filter (s: !(isV6 s)) adSources;
      v6 = lib.filter isV6 adSources;
      mkRange = family: srcs:
        lib.optionalString (srcs != []) ''
          ${family} { ${lib.concatStringsSep ", " srcs} } tcp dport 49152-65535 accept
        '';
    in
      mkRange "ip saddr" v4 + mkRange "ip6 saddr" v6);
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
  # 2. (NO LONGER MANUAL.) The upstream forwarder is converged by the daemon's
  #    ExecStartPre from `krg.sambaAD.dnsForwarder` — do NOT hand-edit
  #    `dns forwarder` in smb.conf; change the option and rebuild. Hand-editing
  #    is what left the live file with two conflicting forwarder lines pointing
  #    at a public resolver that cannot see the internal-only *.ucsd.edu records.
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
