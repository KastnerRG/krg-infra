# CROSS-REFERENCE: the OS baseline here (timezone, packages incl tmux, SSH
# hardening, auto-updates, sysctl, fail2ban, firewall) has a Proxmox/Debian
# counterpart under ansible/roles/ (base, ssh_hardening, fail2ban, krg_admin).
# When you change the baseline on either side, apply the equivalent to the other.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.base;
  # Shared trusted-network data — single source of truth, also consumed by the
  # Ansible layer (cluster.fw IPSets + group_vars). Edit nix/networks/trusted.json.
  trusted = builtins.fromJSON (builtins.readFile ../networks/trusted.json);
in {
  imports = [
    ../modules/security/oec-qualys-trellix.nix
    ../modules/security/fail2ban.nix
    ../modules/security/firewall.nix
    ../modules/security/crowdsec.nix
    ../modules/security/crowdsec-bouncer.nix
    ../modules/services/node-exporter.nix
    ../modules/sssd-ad-client.nix
  ];

  options.krg.base = {
    enable = mkEnableOption "KRG base system configuration";

    timezone = mkOption {
      type = types.str;
      default = "America/Los_Angeles";
    };

    autoUpgrade = mkOption {
      type = types.bool;
      default = true;
      description = "Enable automatic flake-based system upgrades (replaces unattended-upgrades)";
    };

    flakeUrl = mkOption {
      type = types.str;
      # The flake lives in the nix/ subtree of the krg-infra monorepo.
      default = "github:KastnerRG/krg-infra?dir=nix";
      description = "Flake URL used for auto-upgrades";
    };

    isVM = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether this host is a Proxmox/QEMU virtual machine. Enables the QEMU
        guest agent (graceful shutdown, IP reporting to the hypervisor). It does
        NOT disable the NixOS firewall — the in-guest firewall stays on for
        defense-in-depth and so fail2ban has a backend (Proxmox adds an
        additive perimeter layer on top, it does not replace the guest firewall).
      '';
    };

    serviceHost = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Service host (vs compute): restrict in-guest SSH to the trusted UCSD nets
        (mirrors the Proxmox perimeter). **DEFAULT TRUE** — the base policy is
        strict SSH (ucsd + ops only). Compute hosts (waiter et al.) opt OUT
        via `krg.base.serviceHost = false` in their profile, which clears
        sshSources and leaves SSH globally reachable.

        On compute hosts, what catches attackers behind the globally-open
        SSH port is the fleet CrowdSec stack:
          * Community blocklists (CAPI): ~30K-50K continuously-updated
            known-malicious IPs pushed to the bouncer's drop set.
            Commodity scanners pre-banned before they ever try us.
          * Local `ssh-bf` scenario (crowdsecurity/sshd): bans an IP
            for 4h after ~10 failed SSH auths in 10 min, catching the
            gap between first attack and CAPI propagation.
          * Whitelist: ucsd + sealab + ops + machines never raise alerts.
        Country enrichment is NOT wired in this PR (no scenario branches
        on country, so the MaxMind operational footprint would buy
        nothing); add via per-host `services.geoipupdate` + the
        `crowdsecurity/geoip-enrich` parser if/when a country-aware
        scenario lands. See docs/working-remotely.md for the `ops`
        workflow.
      '';
    };
  };

  config = mkIf cfg.enable {
    time.timeZone = cfg.timezone;

    i18n.defaultLocale = "en_US.UTF-8";

    # SSH hardening (replaces Ansible SSH hardening task): key-only auth,
    # and only ed25519 public keys are accepted — RSA/ECDSA are rejected.
    services.openssh = {
      enable = true;
      # krg.firewall owns SSH gating (fleet policy — issue #74). 22 lives
      # in `krg.firewall.allowedTCPPorts` (compute hosts: globally open,
      # CrowdSec drops attackers) or moves to `sshSources` (service hosts:
      # ucsd + ops only). Letting openssh open 22 globally here would
      # shadow that on service hosts — concat-merge into networking.firewall
      # would add a globally-open 22 rule alongside our source-restricted
      # one, and globally-open wins.
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        X11Forwarding = false;
        # Restrict pubkey auth to ed25519 only (rejects ssh-rsa/rsa-sha2-*).
        PubkeyAcceptedAlgorithms = "ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,sk-ssh-ed25519@openssh.com,sk-ssh-ed25519-cert-v01@openssh.com";
      };
    };

    # Campus-mandated endpoint security on EVERY machine: Qualys Cloud Agent
    # (vulnerability management) + Trellix HX (EDR/anti-malware). The agents are
    # proprietary and install from a vendor archive — set
    # krg.oecQualysTrellix.installerArchive per host or they stay dormant.
    krg.oecQualysTrellix.enable = true;

    # Prometheus node exporter on every machine (native systemd service).
    # Hosts that run node_exporter another way override this — e.g. waiter's
    # Docker monitoring stack binds 9100 on the host network, so compute.nix
    # sets krg.nodeExporter.enable = false to avoid a port clash.
    krg.nodeExporter.enable = mkDefault true;

    # Fail2ban is SUPERSEDED by the CrowdSec stack (krg.crowdsec, below).
    # CrowdSec is a fail2ban superset: same SSH brute-force jail surface,
    # plus community blocklists and fleet-wide CTI sharing.
    # Running both creates conflicting ban tables (fail2ban manages iptables;
    # the bouncer manages its own nftables sets) — toggle to OFF here and
    # leave the module in place for one release cycle so we can flip back
    # quickly if CrowdSec misbehaves in prod. Remove the module entirely
    # once CrowdSec has cooked for a quarter.
    krg.fail2ban.enable = mkDefault false;
    krg.fail2ban.ignoreIP =
      mkDefault
      (["127.0.0.1/8" "::1"] ++ map (e: e.cidr) trusted.ipsets.sealab);

    # In-guest firewall (krg.firewall → nftables) on EVERY host, VMs included.
    # Defense-in-depth: this owns *which ports* a service exposes and gives
    # fail2ban a backend to insert bans into (the dictionary attack that drove
    # this rebuild is exactly what fail2ban mitigates). On Proxmox VMs the
    # hypervisor firewall is an *additive* perimeter that owns *which sources*
    # may reach the VM — it does not replace this layer. A host can still set
    # krg.firewall.enable = false explicitly if it really must.
    krg.firewall.enable = mkDefault true;

    # Prometheus scrape source — sourced from the shared trusted-networks file
    # so the monitoring host isn't duplicated across nix / ansible / PVE.
    krg.firewall.monitoringSourceIp = mkDefault trusted.monitoring_host;

    # Fleet-wide CrowdSec stack (partial answer to issue #74's
    # "no public access — US is the floor"). Every host runs:
    #   * services.crowdsec — reads sshd journalctl, runs community
    #     scenarios (linux + sshd hub collections; ssh-bf etc.) + a
    #     parser whitelist for ucsd/sealab/ops/machines.
    #   * services.crowdsec-firewall-bouncer — pulls CrowdSec decisions
    #     every 10s, drops banned IPs via a separate nftables table.
    # What this DOES deliver: strict-tier hosts source-restrict SSH to
    # ucsd+ops at the firewall (`krg.firewall.sshSources` below);
    # compute-tier hosts are globally open behind CAPI community
    # blocklists (~30K-50K continuously-updated malicious IPs, pre-banned
    # before they ever try us) + local ssh-bf (catches first-of-kind
    # attackers within ~10 failed auths). What this does NOT deliver:
    # country gating. No GeoIP enrichment, no scenario branching on
    # country code — non-US sources that haven't tripped CAPI reach
    # compute SSH unmolested. Add a country-aware scenario later if
    # that gap matters: services.geoipupdate + the
    # crowdsecurity/geoip-enrich parser + a scenario branching on
    # evt.Enriched.IsoCode. Per-host disable: `krg.crowdsec.enable
    # = false` (e.g. for a host under maintenance).
    krg.crowdsec.enable = mkDefault true;
    krg.crowdsecBouncer.enable = mkDefault true;

    # Every host gets SSH reachable by default. With `serviceHost = true`
    # (the base default), sshSources tightens 22 to ucsd+ops in-guest and
    # this `allowedTCPPorts = [22]` entry is dropped from the globally-open
    # list (the stricter rule wins). On compute hosts (serviceHost = false),
    # 22 stays in allowedTCPPorts and is globally reachable — CrowdSec is
    # the gating layer there. Per-host configs only override to ADD ports
    # (e.g. server.nix adds 443) — they shouldn't need to re-declare 22.
    krg.firewall.allowedTCPPorts = mkDefault [22];

    # Service hosts restrict in-guest SSH to the trusted nets (mirrors the Proxmox
    # perimeter); compute hosts keep SSH globally open behind CrowdSec.
    # ucsd (institutional) + ops (explicit off-campus admin) — not "ucsd" alone,
    # so remote admin IPs aren't silently folded into the campus set.
    krg.firewall.sshSources =
      mkIf cfg.serviceHost
      (map (e: e.cidr) (trusted.ipsets.ucsd ++ (trusted.ipsets.ops or [])));

    # If a host opens RDP (krg.firewall.allowRDP — compute boxes with the XRDP
    # desktop), restrict 3389 to the trusted UCSD nets in-guest. RDP isn't
    # key-only and has no fail2ban jail, so it must never be globally open on a
    # public-IP box. UCSD only (not ops/off-campus) — reach it over VPN/campus or
    # the planned Guacamole. Inert until allowRDP = true; override per host if needed.
    krg.firewall.rdpSources = mkDefault (map (e: e.cidr) trusted.ipsets.ucsd);

    # Every host is an Active Directory client: it joins KRG.LOCAL and humans log in
    # with their AD accounts (only the nix/users/admin.nix break-glass admin stays
    # local). Access defaults to Domain Admins — widen per host (e.g. compute opens
    # to a lab-users group). SSH stays key-only; keys are served from AD. Member
    # hosts need a one-time domain join for their keytab; the DC (directory.nix sets
    # isDomainController) exports its own. CROSS-REFERENCE: ansible roles/ad_client
    # is the Debian/PVE counterpart, composed into the ansible base role.
    # SPOF NOTE: a single DC is pinned today. When the planned second DC lands on
    # another Proxmox host (CLAUDE.md pending items), let members fail over —
    # either set server/serverIp to null for SRV autodiscovery, or extend the
    # module to list both DCs (and pin both in /etc/hosts).
    krg.adClient = {
      enable = mkDefault true;
      server = mkDefault "krg-ldap.krg.local";
      serverIp = mkDefault "137.110.161.109"; # krg-ldap (pin so members resolve the DC)
      allowedGroups = mkDefault ["Domain Admins"];
      # Domain Admins get sudo (password-required) on every host; the local
      # break-glass admin (users/admin.nix) keeps its own NOPASSWD rule.
      sudoGroups = mkDefault ["Domain Admins"];
      sshKeysFromAD = mkDefault true;
    };

    # QEMU guest agent on VMs (graceful shutdown + IP reporting to Proxmox).
    services.qemuGuest.enable = mkDefault cfg.isVM;

    # kernel.sysrq = 1 (from waiter sysctl.d/90-sysrq.conf)
    boot.kernel.sysctl."kernel.sysrq" = 1;

    # Replaces APT unattended-upgrades; pulls the flake and rebuilds.
    #
    # Deliberately builds from the COMMITTED flake.lock — no per-host nixpkgs
    # re-resolution. The autoUpgrade module already appends `--refresh --flake
    # <url>`, so each host fetches the latest `main` and builds the exact pinned
    # nixpkgs everyone else builds. We do NOT pass `--update-input nixpkgs`
    # (that made every host re-resolve nixpkgs independently → fleet drift, and
    # silently ignored the lock) nor `--commit-lock-file` (a no-op against a
    # read-only github: ref).
    #
    # FLEET-WIDE nixpkgs UPDATE = ONE step: in nix/, run `nix flake update nixpkgs`
    # (or `nix flake update`), commit + push to main. CI builds it; the next 04:00
    # tick rolls it out to every host from the new pinned lock.
    system.autoUpgrade = mkIf cfg.autoUpgrade {
      enable = true;
      allowReboot = false;
      # Pin the flake ATTRIBUTE to this host's intended config name. Without the
      # explicit #${hostName}, nixos-rebuild infers the attribute from the host's
      # RUNTIME hostname — so a box that booted under the wrong/default name (a
      # fresh install still called "nixos") silently builds a nonexistent
      # nixosConfigurations."nixos" and the upgrade fails EVERY night with no
      # signal. Pinning targets the intended config regardless of runtime hostname
      # and self-heals the name on the next switch. (krg-vault was stuck ~2.5 weeks
      # on a stale generation this way — no security patches, no key updates.)
      flake = "${cfg.flakeUrl}#${config.networking.hostName}";
      dates = "04:00";
    };

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true; # dedup store paths (hardlink) on every build
    };

    # Automatic garbage collection (NixOS wiki: Storage optimization → Automation).
    # Weekly, keeping a 30-day rollback window. Matters here because the nightly
    # autoUpgrade creates a new generation every day, so the store would otherwise
    # grow without bound.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      git
      git-lfs
      curl
      wget
      htop
      vim
      tmux
    ];
  };
}
