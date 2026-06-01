# krg.crowdsec — fleet-wide CrowdSec Security Engine.
#
# Thin wrapper over upstream services.crowdsec. Implements the fleet
# "no public access — US is the floor" policy (issue #74) reactively:
# CrowdSec reads sshd logs from journalctl (the fleet baseline — every
# host has sshd), evaluates community scenarios + a local trusted-net
# whitelist, and emits DECISIONS (4h IP bans by default) that the
# firewall bouncer picks up and drops at nftables.
#
# Other log sources (e.g. traefik access logs on krg-prod/e4e-prod) are
# OPT-IN per host via `krg.crowdsec.extraAcquisitions` +
# `krg.crowdsec.extraCollections`. NOT enabled by default in this PR;
# wire them up per host when the corresponding service lands.
#
# WHY THIS REPLACES THE STATIC GEOIP SET (closed PR #90):
#   Pre-loading 163K v4 + 254K v6 MaxMind US CIDRs into a single
#   nftables transaction hit netlink ENOBUFS regardless of chunking
#   strategy (named sets, anonymous inline sets, chunked add-element
#   commands all failed). CrowdSec sidesteps the problem entirely:
#   decisions live in a small DYNAMIC ban set populated only by IPs
#   that have actually misbehaved (community-flagged or scenario-
#   tripping locally). No pre-loaded geo data needed — see below for
#   what does the actual filtering.
#
# COVERAGE:
#   * crowdsecurity/linux + crowdsecurity/sshd hub collections:
#     ssh-bf (brute-force), ssh-slow-bf, ssh-cve scenarios — the
#     fail2ban replacement. CrowdSec's ssh-bf has lower FPR than
#     fail2ban's jail.d/sshd because it correlates events across
#     parsers rather than just grep-matching auth.log.
#   * Community blocklists (CrowdSec CAPI): activated by wiring
#     `capi.credentialsFile` (see config block below). The setup
#     script auto-registers each host with api.crowdsec.net on first
#     activation; from then on, the LAPI pulls the global community
#     decision feed (~30K-50K malicious IPs at any moment, refreshed
#     continuously by the worldwide CrowdSec fleet). This is the
#     practical "US floor" — commodity scanners hit thousands of
#     CrowdSec users in parallel, so attacker IPs land in CAPI
#     within minutes of first attack and into our bouncer's drop
#     set on the next 10s poll, usually BEFORE they ever try us.
#   * Local whitelist: ucsd + sealab + ops CIDRs from trusted.json never
#     trigger bans. ops is the manual-override slot for traveling staff
#     (see docs/working-remotely.md).
#
# WHAT'S DELIBERATELY OUT OF SCOPE:
#   * Country-aware scenarios (e.g. "drop non-US first packet to port
#     N"). Would require services.geoipupdate + the
#     crowdsecurity/geoip-enrich parser + a scenario that branches on
#     evt.Enriched.IsoCode. None of those are wired here because no
#     scenario in this PR uses country info — adding them would add
#     operational footprint (MaxMind account, license-key file per
#     host) with zero current benefit. Add later if/when we write a
#     country-aware scenario.
#
# ARCHITECTURAL SHIFT FROM PR #90:
#   PR #90 dropped non-US packets on first arrival. CrowdSec lets the
#   first packet through (a fraction of a second), bans the IP after
#   it trips ANY scenario or matches community CTI. In practice this is
#   STRICTER posture (caught attackers stay banned fleet-wide for 4h;
#   community-shared decisions cover IPs we've never seen), but the
#   failure shape is different — a brand-new well-behaved foreign
#   scanner might land one connection before getting banned. The original
#   docstring called this "attack surface noise reduction"; CrowdSec
#   delivers that goal more effectively than the static set could have.
#
# DEPENDENCIES:
#   * krg.crowdsecBouncer.enable = true (applies decisions to nftables).
#   * trusted.json (read directly here for the local whitelist — no
#     option duplication; same source as krg.firewall.sshSources).
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.crowdsec;
  trusted = builtins.fromJSON (builtins.readFile ../../networks/trusted.json);

  # Flatten ucsd + sealab + ops + machines into the whitelist source set.
  # Same nets as the proxmox perimeter + krg.firewall. If an entry is
  # missing from trusted.json (e.g. ops not yet defined), default to [];
  # the whitelist still works with the present sets.
  #
  # CrowdSec's whitelist parser distinguishes `ip:` (bare host
  # addresses) from `cidr:` (prefixed ranges). trusted.json mixes both
  # — e.g. ucsd has 137.110.0.0/16 (CIDR) alongside 137.110.161.106
  # (bare host). Split here so the parser doesn't choke on a bare IP
  # under `cidr:` or silently drop it.
  whitelistEntries =
    map (e: e.cidr) (
      (trusted.ipsets.ucsd or [])
      ++ (trusted.ipsets.sealab or [])
      ++ (trusted.ipsets.ops or [])
      ++ (trusted.ipsets.machines or [])
    );
  whitelistBareIPs = filter (e: !(hasInfix "/" e)) whitelistEntries;
  whitelistCidrs   = filter (e:   hasInfix "/" e ) whitelistEntries;
in {
  options.krg.crowdsec = {
    enable = mkEnableOption ''
      CrowdSec Security Engine — reads journalctl, runs community +
      local scenarios, emits ban decisions consumed by the firewall
      bouncer. Replaces fail2ban (which is toggled off in base.nix
      when this is on)
    '';

    extraCollections = mkOption {
      type        = types.listOf types.str;
      default     = [];
      example     = [ "crowdsecurity/traefik" ];
      description = ''
        Additional CrowdSec hub collections to install on top of the
        fleet baseline (linux + sshd). Service hosts running Traefik
        should add `crowdsecurity/traefik`; web-app hosts add the
        relevant app collection (e.g. nextcloud, gitea). Browse
        https://hub.crowdsec.net/ for the full catalog.
      '';
    };

    extraAcquisitions = mkOption {
      type        = types.listOf (types.attrsOf types.anything);
      default     = [];
      example     = lib.literalExpression ''
        [{
          source = "file";
          filenames = [ "/var/log/traefik/access.log" ];
          labels.type = "traefik";
        }]
      '';
      description = ''
        Additional log-source specs beyond the fleet-default sshd
        journalctl acquisition. Service hosts running Traefik add the
        traefik access log here; compute hosts typically need nothing.

        Each entry is a raw acquisition spec — see
        https://docs.crowdsec.net/docs/data_sources/intro for the
        shape (source, journalctl_filter / filenames / etc.).
      '';
    };
  };

  config = mkIf cfg.enable {
    services.crowdsec = {
      enable           = true;
      # Keep the hub index fresh (daily cscli hub update) so new
      # community scenarios + blocklists land without a fleet redeploy.
      autoUpdateService = true;

      hub = {
        collections =
          # The fleet baseline:
          #   * linux — generic Linux log parsing + meta-scenarios.
          #   * sshd  — ssh-bf, ssh-slow-bf, ssh-cve. Replaces fail2ban.
          # Each collection brings its required parsers + scenarios so
          # we don't have to list them piecemeal.
          [ "crowdsecurity/linux" "crowdsecurity/sshd" ]
          ++ cfg.extraCollections;

        # No parsers listed: country enrichment (crowdsecurity/geoip-enrich)
        # is intentionally NOT installed here — no scenario in this PR
        # branches on country, so the enrichment + the mmdb operational
        # footprint (MaxMind account, license-key file per host) would
        # buy nothing. Add via per-host `services.crowdsec.hub.parsers`
        # if/when a country-aware scenario lands.
      };

      localConfig = {
        # Sources. Default fleet acquisition: sshd via journalctl
        # (every host runs sshd, every host runs systemd-journald).
        # Per-host extras (traefik access log, etc.) come from
        # `extraAcquisitions`.
        acquisitions = [
          {
            source = "journalctl";
            journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
            labels.type = "syslog";
          }
        ] ++ cfg.extraAcquisitions;

        # s02-enrich whitelist: events from our trusted nets never
        # raise alerts, so they never produce decisions, so the bouncer
        # never bans them. Same CIDR set as the Proxmox perimeter +
        # krg.firewall.sshSources — single source of truth in
        # nix/networks/trusted.json. ops is the manual-override slot
        # for traveling staff (docs/working-remotely.md): add a CIDR
        # to ops before flying, the whitelist picks it up on the next
        # autoUpgrade rebuild, never get caught in a community ban.
        parsers.s02Enrich = [
          {
            name        = "krg/trusted-nets-whitelist";
            description = "Skip alerts from ucsd + sealab + ops + machines (trusted.json)";
            whitelist = {
              reason = "trusted KRG network (ucsd/sealab/ops/machines)";
            } // (lib.optionalAttrs (whitelistBareIPs != []) { ip   = whitelistBareIPs; })
              // (lib.optionalAttrs (whitelistCidrs   != []) { cidr = whitelistCidrs;   });
          }
        ];

        # Profiles control how alerts → decisions. The upstream module
        # default (4h IP ban on Alert.Remediation == true && scope=='Ip')
        # is fine for the fleet; leave it untouched. Operators can
        # override via `services.crowdsec.localConfig.profiles` on a
        # per-host basis if a particular host needs longer/shorter bans
        # (e.g. krg-vault with a 24h ban for OpenBao API abusers).
      };

      settings = {
        # Enable the LAPI server on 127.0.0.1:8080 so the bouncer
        # (running on the same host) can pull decisions. Without this,
        # the bouncer has nothing to read.
        general.api.server.enable = true;

        # LAPI credentials file. cscli writes machine credentials here
        # on first activation via the setup script (`cscli machine add
        # ${hostName} --auto`). Without this path set, the upstream
        # module's setup script null-coerces (it interpolates the path
        # into a `[ ! -s "..." ]` shell test) and evaluation fails.
        # Stays under /var/lib/crowdsec/state alongside the sqlite DB.
        lapi.credentialsFile = "/var/lib/crowdsec/state/local_api_credentials.yaml";

        # CAPI (CrowdSec central API) credentials file. Setting this
        # path activates two things on first activation:
        #   1. The setup script auto-runs `cscli capi register` (when
        #      the file doesn't yet contain a password line), which
        #      contacts api.crowdsec.net, mints a random machine ID +
        #      password for THIS host, and writes them here.
        #   2. The upstream defaults for `api.server.online_client.pull`
        #      (community = true, blocklists = true) and .sharing = true
        #      stop being silent no-ops — they USE these credentials to
        #      pull the community decision feed (~30K-50K malicious IPs,
        #      updated continuously by the global CrowdSec fleet) and
        #      to push our own observed-attacker decisions back.
        # The community feed is the practical "US floor" replacement:
        # commodity scanners/brute-forcers get added to CAPI within
        # ~minutes of starting attacks anywhere in the world (the same
        # bots hit thousands of CrowdSec users in parallel), so most
        # actual attacker IPs land in our bouncer's drop set BEFORE
        # they ever try us. The local ssh-bf scenario catches the gap
        # for first-of-kind attackers within ~5-10 failed auths.
        # FIRST-RUN REQUIREMENT: outbound TCP/443 to api.crowdsec.net
        # at activation. The file must already EXIST (even empty) before
        # any cscli command runs — see the crowdsec-seed-capi-credfile
        # ExecStartPre below for why. Once it exists, registration is
        # idempotent: the upstream setup's grep-for-password gate skips
        # `cscli capi register` after the first success, and an empty
        # file just downgrades to a "missing login field" warning (the
        # daemon still starts, CAPI pull is simply inactive) so a host
        # that can't reach api.crowdsec.net on first deploy fills the
        # file in on the next reachable rebuild instead of wedging.
        capi.credentialsFile = "/var/lib/crowdsec/state/online_api_credentials.yaml";
      };
    };

    # Seed an EMPTY online_api_credentials.yaml before the upstream
    # crowdsec setup runs. WHY: setting capi.credentialsFile above puts
    # `api.server.online_client.credentials_path` into config.yaml, and
    # cscli EAGERLY loads that file on every command that loads the
    # Local API. The file is only created by `cscli capi register` —
    # but the upstream setup runs `cscli machine add` FIRST, which also
    # loads the LAPI, so on a fresh host machine-add dies with
    #   "failed to load Local API: loading online client credentials:
    #    open .../online_api_credentials.yaml: no such file or directory"
    # That aborts the setup script (set -euo pipefail), fails
    # crowdsec.service, and the firewall-bouncer-register service (which
    # only `wants` crowdsec.service) then runs anyway and fails with a
    # 243/CREDENTIALS error — the failure that rolled back PR #96.
    #
    # cscli treats a MISSING file as fatal but an EMPTY file as a soft
    # "missing login field" warning, so pre-creating it breaks the
    # bootstrap deadlock: machine-add warns+succeeds, then the setup's
    # own `cscli capi register` fills in the real CAPI credentials.
    # mkBefore runs this as the first ExecStartPre so it executes under
    # the same (DynamicUser) service identity as the setup script —
    # ownership is therefore correct without any static crowdsec user.
    systemd.services.crowdsec.serviceConfig.ExecStartPre = lib.mkBefore [
      (pkgs.writeShellScript "crowdsec-seed-capi-credfile" ''
        set -eu
        f=${lib.escapeShellArg config.services.crowdsec.settings.capi.credentialsFile}
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
        [ -e "$f" ] || : > "$f"
      '')
    ];
  };
}
