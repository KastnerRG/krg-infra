# krg.firewall — the single switch for the in-guest OS firewall (nftables).
#
# Fleet-wide policy (set in profiles/base.nix, expressible per-host):
#   * NO PORT IS GLOBALLY OPEN BY DEFAULT. The strict default for SSH is
#     ucsd + ops (via krg.base.serviceHost); compute hosts opt OUT for
#     wider reach. The fleet attacker-eviction policy is enforced
#     behind the firewall by the CrowdSec stack (services.crowdsec +
#     services.crowdsec-firewall-bouncer). See
#     nix/modules/security/crowdsec.nix.
#
#     Issue #74 calls the policy "no public access — US is the floor".
#     What's actually enforced here is closer to "no public access
#     except behaviorally-vetted": CrowdSec CAPI community blocklists
#     pre-ban known-malicious sources (regardless of country) and local
#     ssh-bf catches first-of-kind attackers. There's NO country gate
#     in this PR — non-US sources that haven't tripped CAPI can still
#     reach compute SSH. Add a country-aware scenario later if that gap
#     matters (services.geoipupdate + the crowdsecurity/geoip-enrich
#     parser + a scenario branching on evt.Enriched.IsoCode).
#
#   * The four operator-facing port lists, from most-restrictive to least:
#
#     sourcedPorts      — explicit per-port source restriction (operator picks
#                         the CIDRs). Use for internal-only protocols where
#                         even US is too loose — e.g. OpenBao 8200 sealab-only
#                         on krg-vault, AD ports sealab-only on krg-ldap.
#     sshSources        — SSH-specific (port 22) tightening for service hosts.
#                         Mirrors the Proxmox perimeter (ucsd + ops nets).
#     allowedTCPPorts   — "reachable per the host's policy". With CrowdSec on
#                         (the fleet default), the in-guest firewall opens
#                         these ports globally — CrowdSec's bouncer drops
#                         attackers behind them via a separate nftables table
#                         (decisions live in a small dynamic ban set, not a
#                         giant pre-loaded allowlist).
#     publicPorts       — EXPLICIT opt-IN-to-globally-public. The escape
#                         hatch for protocols where source restriction
#                         breaks legitimate clients (ACME HTTP-01 from
#                         Let's Encrypt's multi-perspective validators —
#                         see krg-vault). Each entry SHOULD have an inline
#                         `# reason:` comment for review.
#
#     Functionally, `allowedTCPPorts` and `publicPorts` both land in
#     networking.firewall.allowedTCPPorts today — CrowdSec is the layer
#     that distinguishes them at runtime via its decision set. They're kept
#     distinct in the option surface so the operator's intent is explicit
#     (publicPorts requires a reason; allowedTCPPorts inherits the fleet
#     CrowdSec policy by default).
#
#   * The four lists are intersected with disjointness assertions (see
#     `config.assertions` below) so operator can't silently put a port in
#     two contradictory lists (closes #83). If you put port N in:
#       allowedTCPPorts AND publicPorts → assertion fires (opposite intent)
#       allowedTCPPorts AND sourcedPorts → assertion fires (sourcedPorts
#                                          wins; listing in both is redundant)
#       publicPorts AND sourcedPorts → assertion fires (opposite intent)
#
#   * Service hosts (krg.base.serviceHost = true) automatically get
#     sshSources populated from trusted.json's ucsd + ops nets, so 22 is
#     already tighter than the fleet CrowdSec policy there. The disjointness
#     handling excludes sshSources-covered 22 from the globally-open list
#     (the stricter rule wins).
#
# Cross-references:
#   * CrowdSec module: nix/modules/security/crowdsec.nix
#     (acquisitions, scenarios, parser whitelist for trusted IPSets).
#   * Trusted IPSets: nix/networks/trusted.json (shared with the Ansible
#     proxmox_firewall layer; consumed by the CrowdSec whitelist).
#   * The fleet policy and the `ops` escape hatch for traveling staff
#     is documented in docs/working-remotely.md.
{ config, lib, ... }:
with lib;
let
  cfg = config.krg.firewall;
  # nftables uses different match keywords for v4 (`ip saddr`) vs v6
  # (`ip6 saddr`). Pick by colon presence — only v6 has colons.
  isV6 = src: hasInfix ":" src;

  # Emit ONE rule per port per family using nftables anonymous inline
  # sets (`ip saddr { cidr1, cidr2, ... } proto dport N accept`) instead
  # of one rule per (port × CIDR). nftables auto-builds an interval tree
  # for CIDR-bearing inline sets, so lookup stays O(log n) regardless of
  # set size — and one rule replaces many. The operator-supplied source
  # lists here are small (dozens at most — sealab/ucsd/ops); the giant
  # MaxMind set is NOT loaded here (that's CrowdSec's job; see the file
  # header for the architectural split).
  inlineSet = cidrs: "{ " + concatStringsSep ", " cidrs + " }";

  # Render a per-port rule for one protocol+family. Returns "" if the
  # source list is empty (don't emit a rule that matches nothing).
  mkPortRule = { proto, family, port, sources }:
    if sources == [] then ""
    else "${family} ${inlineSet sources} ${proto} dport ${toString port} accept\n";

  # Render both v4 and v6 rules for a sourcedPort entry. Splits sources
  # by family so each rule references a single-family set (nftables
  # requires this; `ip saddr` can't reference an ipv6 set).
  mkSourcedRules = proto: { port, sources }:
    let
      v4 = filter (s: !(isV6 s)) sources;
      v6 = filter isV6 sources;
    in
      mkPortRule { inherit proto port; family = "ip saddr";  sources = v4; }
      + mkPortRule { inherit proto port; family = "ip6 saddr"; sources = v6; };
in {
  options.krg.firewall = {
    enable = mkEnableOption "KRG firewall (replaces UFW)";

    allowedTCPPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = ''
        Ports the host wants reachable. Land in
        `networking.firewall.allowedTCPPorts` (globally open at the
        nftables INPUT layer). With the fleet CrowdSec stack enabled
        (the default per `profiles/base.nix`), the
        crowdsec-firewall-bouncer's separate `crowdsec`/`crowdsec6`
        nftables tables drop traffic from IPs that CrowdSec has banned
        (community CAPI decisions + locally-triggered scenarios like
        ssh-bf). The bouncer drops by SOURCE IP regardless of which
        port is reached, so this filter applies to every port we open
        — `publicPorts` doesn't bypass it either.

        `publicPorts` is functionally identical at the nftables layer;
        the only difference is intent + grep-ability (publicPorts
        documents an exception with a required reason comment). Use
        `publicPorts` for ports where an operator has thought through
        the trade-off (today: ACME HTTP-01 challenge from anywhere);
        use `allowedTCPPorts` for the host's normal services.

        Interaction with the other port lists:
          * `sshSources` (22 on service hosts) silently moves 22 out of
            the globally-open list. No assertion fires for an overlap
            here — it's the expected configuration on service hosts.
          * `sourcedPorts` (operator-explicit per-port restriction) wins
            over the globally-open default. Listing a port in BOTH is
            REDUNDANT — a per-PR assertion (`allowedTCPPorts ∩
            sourcedPorts`) flags the duplicate so the operator drops one.
          * `publicPorts` is an "intent signal" overlap. A per-PR
            assertion fires when a port is in both; pick one.

        Default empty so a host that adds this module without explicit
        configuration gets the minimal attack surface (no in-guest ports
        beyond what `monitoringPorts`/`sshSources` open).
      '';
    };

    publicPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      example     = [ 80 ];
      description = ''
        Ports that MUST be globally reachable — no source restriction.
        EXPLICIT opt-IN escape hatch for protocols where source
        restriction breaks legitimate clients. Each entry SHOULD have an
        inline `# reason: ...` comment for PR review.

        Today's only legitimate use case: ACME HTTP-01 challenge port 80.
        Let's Encrypt does multi-perspective validation from validators
        in multiple countries (US + EU + Asia); a country-gated port 80
        would fail cert issuance/renewal. Other hosts running ACME
        HTTP-01 will need the same opt-in.

        Functionally these land in `networking.firewall.allowedTCPPorts`
        the same as `allowedTCPPorts` — the distinction is intent
        (publicPorts documents the exception for grep + review).
      '';
    };

    allowedUDPPorts = mkOption {
      type    = types.listOf types.port;
      default = [];
    };

    # Ports only reachable from the KRG Prometheus scraping host
    # (krg-prod; set via monitoringSourceIp below, sourced from trusted.json).
    monitoringPorts = mkOption {
      type        = types.listOf types.port;
      default     = [];
      description = "Ports open only to monitoringSourceIp (Prometheus scraping)";
    };

    monitoringSourceIp = mkOption {
      type    = types.str;
      # Fallback only — base.nix sets this on every host from trusted.json's
      # monitoring_host (currently krg-prod). Kept in sync to avoid a stale value.
      default = "137.110.161.106";
    };

    allowRDP = mkOption {
      type        = types.bool;
      default     = false;
      description = "Open port 3389 for XRDP (waiter compute nodes)";
    };

    rdpSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        When allowRDP is set: if non-empty, 3389 is reachable ONLY from these
        CIDRs/IPs (source-restricted in-guest); if empty, 3389 is opened globally.
        On a public-IP compute box you want this set — base.nix defaults it to the
        trusted UCSD nets so RDP is never exposed to the whole internet (RDP is not
        key-only). Inert unless allowRDP = true.
      '';
    };

    sshSources = mkOption {
      type        = types.listOf types.str;
      default     = [];
      description = ''
        If non-empty, SSH (port 22) is reachable ONLY from these CIDRs/IPs
        in-guest, instead of being globally open. Service hosts set this (mirrors
        the Proxmox perimeter). Compute hosts leave it empty (CrowdSec gates
        SSH attackers behind a globally-open 22).
        Usually set via krg.base.serviceHost.
      '';
    };

    sourcedPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      description = ''
        TCP ports reachable ONLY from specific source CIDRs/IPs in-guest.
        Use for services that should be internal-only (e.g. OpenBao API on
        sealab nets) while still benefiting from in-guest defense-in-depth.
        Each entry: { port = <N>; sources = [ "cidr1" "cidr2" ... ]; }

        Sources can be either IPv4 (`1.2.3.0/24`) or IPv6 (`2001:db8::/32`);
        the module picks the right nftables match (`ip saddr` vs `ip6 saddr`)
        per-entry by detecting the colon.

        STRICTER than `allowedTCPPorts`'s CrowdSec-gated default — use this
        when even the fleet US-floor / community-blocklist policy is too
        loose (e.g. sealab-only). The globally-open allowedTCPPorts
        computation excludes ports listed here, so the tighter rule wins
        without operator coordination.

        See `sourcedUDPPorts` for the UDP counterpart (samba-ad uses both
        for its DNS / Kerberos / CLDAP UDP surfaces).
      '';
    };

    sourcedUDPPorts = mkOption {
      type    = types.listOf (types.submodule {
        options = {
          port    = mkOption { type = types.port; };
          sources = mkOption { type = types.listOf types.str; };
        };
      });
      default     = [];
      description = ''
        UDP counterpart of `sourcedPorts`. Same shape, same dual-stack
        v4/v6 source handling. Used by samba-ad on krg-ldap to keep DNS,
        Kerberos, and CLDAP UDP surfaces sealab-only.
      '';
    };
  };

  config = mkMerge [
    # krg.firewall is the single switch for the OS firewall. Enabling it turns
    # on nftables + the rules below; disabling it (e.g. VMs where the hypervisor
    # owns the firewall) explicitly turns the NixOS firewall OFF rather than
    # letting it fall back to its restrictive enabled-by-default state.
    { networking.firewall.enable = cfg.enable; }

    (mkIf cfg.enable (let
      # Ports that already have a per-port restriction. Excluded from
      # the globally-open list (the stricter rule wins).
      sshSourceCovered     = if cfg.sshSources != [] then [ 22 ] else [];
      manualSourcedCovered = map (e: e.port) cfg.sourcedPorts;
      # RDP (3389) is source-restricted when allowRDP=true AND rdpSources
      # is non-empty (a per-source rule is emitted in extraInputRules).
      # If 3389 also appears in allowedTCPPorts, the globally-open rule
      # would shadow the per-source restriction — exclude it here.
      rdpSourceCovered     = optional (cfg.allowRDP && cfg.rdpSources != []) 3389;
      alreadyTighter       = sshSourceCovered ++ manualSourcedCovered ++ rdpSourceCovered;

      # UDP equivalent: ports in sourcedUDPPorts get per-source accept
      # rules in extraInputRules; if also in allowedUDPPorts, the
      # globally-open rule shadows them. Filter here.
      udpSourcedCovered    = map (e: e.port) cfg.sourcedUDPPorts;
    in {
      # Disjointness assertions (closes #83 + extends for publicPorts).
      # A port belongs in ONE list — overlapping lists silently shadow
      # each other or signal contradictory intent.
      assertions = [
        {
          # publicPorts vs allowedTCPPorts: redundant + ambiguous intent.
          # Both lists end up in `networking.firewall.allowedTCPPorts` at
          # the nftables INPUT layer (no functional difference), but
          # publicPorts is the intent signal "globally open by design,
          # with a documented reason comment" and allowedTCPPorts is
          # "host wants this reachable". Listing in both makes the intent
          # ambiguous on review; pick one.
          assertion = builtins.all (p: !(elem p cfg.allowedTCPPorts)) cfg.publicPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH publicPorts and
            allowedTCPPorts. The two lists are functionally identical at
            the firewall layer — the distinction is operator intent
            (publicPorts requires an inline `# reason:` comment for the
            globally-open exception; allowedTCPPorts doesn't). Pick one:
              - publicPorts     = [ N ]   # documented globally-open exception
              - allowedTCPPorts = [ N ]   # normal host service
            Offending overlap: ${toString (filter (p: elem p cfg.allowedTCPPorts) cfg.publicPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # publicPorts vs sourcedPorts: opposite intent (globally open vs
          # source-restricted). sourcedPorts emits accept rules; publicPorts
          # adds to the globally-open list. Globally-open wins. Pick one.
          assertion = builtins.all
            (p: !(elem p (map (e: e.port) cfg.sourcedPorts))) cfg.publicPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH publicPorts and sourcedPorts.
            Opposite intent — pick one:
              - publicPorts                                  # globally open
              - sourcedPorts = [{ port=N; sources=[...]; }]  # restricted
            Offending overlap: ${toString (filter (p: elem p (map (e: e.port) cfg.sourcedPorts)) cfg.publicPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # allowedTCPPorts vs sourcedPorts overlap is REDUNDANT (the
          # sourcedPorts entry's tighter rule wins; the allowedTCPPorts
          # listing is silently shadowed). Loud assertion so operators
          # clean up the duplicate before the bug from #83 can resurface.
          assertion = let
            srcSet = map (e: e.port) cfg.sourcedPorts;
          in builtins.all (p: !(elem p srcSet)) cfg.allowedTCPPorts;
          message = ''
            krg.firewall: port(s) appear in BOTH allowedTCPPorts AND
            sourcedPorts. The sourcedPorts (per-port-restricted) rule
            wins, so the allowedTCPPorts entry is REDUNDANT. Drop the
            duplicate from allowedTCPPorts:
              krg.firewall.sourcedPorts = [{ port=N; sources=[...]; }]
              # remove N from krg.firewall.allowedTCPPorts
            Offending overlap: ${toString (filter (p: elem p (map (e: e.port) cfg.sourcedPorts)) cfg.allowedTCPPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # allowedUDPPorts vs sourcedUDPPorts: same redundancy as the
          # TCP variant above. samba-ad puts AD UDP ports in
          # sourcedUDPPorts (sealab+machines+ops) — without this
          # assertion an operator who also lists them in allowedUDPPorts
          # would silently shadow the restriction.
          assertion = let
            srcSet = map (e: e.port) cfg.sourcedUDPPorts;
          in builtins.all (p: !(elem p srcSet)) cfg.allowedUDPPorts;
          message = ''
            krg.firewall: UDP port(s) appear in BOTH allowedUDPPorts AND
            sourcedUDPPorts. sourcedUDPPorts wins, so the allowedUDPPorts
            entry is REDUNDANT. Drop the duplicate:
              krg.firewall.sourcedUDPPorts = [{ port=N; sources=[...]; }]
              # remove N from krg.firewall.allowedUDPPorts
            Offending overlap: ${toString (filter (p: elem p (map (e: e.port) cfg.sourcedUDPPorts)) cfg.allowedUDPPorts)}
            (host: ${config.networking.hostName})
          '';
        }
        {
          # publicPorts vs source-restricted RDP (3389): if 3389 is in
          # publicPorts AND allowRDP+rdpSources is set, publicPorts wins
          # (it's concatenated unconditionally into the globally-open
          # list), silently defeating the rdpSources restriction. No
          # legitimate use case for this combo — RDP from anywhere is
          # never the intent on a host that bothered to restrict by
          # source. Fire loudly.
          assertion =
            !(cfg.allowRDP && cfg.rdpSources != [] && elem 3389 cfg.publicPorts);
          message = ''
            krg.firewall: port 3389 is in publicPorts AND allowRDP is set
            with rdpSources = [...]. publicPorts is unconditionally
            globally-open, so it shadows the rdpSources restriction. Pick
            one:
              - rdpSources = [...]   # source-restricted (the usual case)
              - publicPorts = [3389] # globally-open RDP (no legitimate
                                     #   use case today; if you really
                                     #   mean it, clear rdpSources first)
            (host: ${config.networking.hostName})
          '';
        }
        {
          # publicPorts vs source-restricted SSH (22): symmetric to the
          # RDP assertion above. Service hosts set `sshSources` to scope
          # SSH to ucsd+ops; if 22 also ends up in publicPorts (e.g. via
          # a typo or a misguided "I want public SSH" override), the
          # globally-open list wins and the source restriction silently
          # evaporates. No legitimate use case — fire loudly.
          assertion =
            !(cfg.sshSources != [] && elem 22 cfg.publicPorts);
          message = ''
            krg.firewall: port 22 is in publicPorts AND sshSources is set
            (host is service-tier). publicPorts is unconditionally
            globally-open, so it shadows the sshSources restriction. Pick
            one:
              - sshSources = [...]   # ucsd + ops only (the usual case)
              - publicPorts = [22]   # globally-open SSH (almost
                                     #   certainly not what you want;
                                     #   clear sshSources first)
            (host: ${config.networking.hostName})
          '';
        }
      ];

      # extraInputRules uses nftables syntax; enable the nftables backend
      networking.nftables.enable = true;

      networking.firewall = {
        # The globally-open list is THE only place we add ports without a
        # source filter. Both publicPorts and allowedTCPPorts land here
        # (CrowdSec is the policy layer that distinguishes them at runtime
        # via its decision set); ports already covered by a tighter rule
        # (sshSources, sourcedPorts) are filtered out. RDP: 3389 only
        # joins globally-open when allowRDP is set AND rdpSources is empty.
        allowedTCPPorts =
          cfg.publicPorts
          ++ filter (p: !(elem p alreadyTighter)) cfg.allowedTCPPorts
          ++ optional (cfg.allowRDP && cfg.rdpSources == []) 3389;
        allowedUDPPorts = filter (p: !(elem p udpSourcedCovered)) cfg.allowedUDPPorts;

        # nftables rules: monitoring-port scraping, source-restricted SSH /
        # RDP / sourcedPorts. ALL use anonymous inline sets (one rule per
        # port per family) instead of one rule per CIDR. See `mkSourcedRules`
        # at the top for the per-family split.
        extraInputRules =
          # Monitoring: one source IP per scrape port. Use mkSourcedRules
          # so the v4/v6 family is picked by colon-detection — a future
          # IPv6 monitoring host would otherwise produce invalid nftables
          # syntax (hardcoded `ip saddr` against an IPv6 address).
          concatMapStrings (port:
            mkSourcedRules "tcp" { inherit port; sources = [ cfg.monitoringSourceIp ]; }
          ) cfg.monitoringPorts
          # SSH (22) from sshSources — one rule per family.
          + mkSourcedRules "tcp" { port = 22; sources = cfg.sshSources; }
          # RDP (3389) from rdpSources — one rule per family.
          + optionalString cfg.allowRDP
              (mkSourcedRules "tcp" { port = 3389; sources = cfg.rdpSources; })
          # sourcedPorts (TCP): operator-explicit per-port restrictions.
          + concatMapStrings (mkSourcedRules "tcp") cfg.sourcedPorts
          # sourcedUDPPorts: same shape, udp.
          + concatMapStrings (mkSourcedRules "udp") cfg.sourcedUDPPorts;
      };
    }))
  ];
}
