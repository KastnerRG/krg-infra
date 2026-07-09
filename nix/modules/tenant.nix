# nixosModules.tenant — the NixOS half of the deploy contract (ADR 0020 §1/§4).
#
# A NixOS-instance tenant imports this and sets `krg.tenant` to its lib.mkTenant spec:
#
#   # <project>/flake.nix
#   nixosConfigurations.<name> = nixpkgs.lib.nixosSystem {
#     modules = [
#       krg-infra.nixosModules.tenant
#       { krg.tenant = krg-infra.lib.mkTenant { name = "..."; zone = "e4e"; ... }; }
#       ./hardware-configuration.nix   # the instance's disk/boot (tenant-owned)
#     ];
#   };
#
# Consuming it brings the lab baseline (AD-join, in-guest firewall, CrowdSec, OEC,
# monitoring — via profiles/server.nix) plus Docker + the compose runner, and wires the
# tenant's compose INTERIOR as a managed stack. The interior is tenant-owned and
# authoritative (repo-owns-deploy): the runner updates the compose; nix just runs it.
#
# DELIBERATELY NOT YET WIRED (gated on later track PRs, flagged so the seam is explicit):
#   • the repo-scoped GitHub runner (needs the GitHub App credential path),
#   • the edge re-encrypt cert (vault-agent issuing `tenant-internal` from the per-tenant
#     AppRole — terraform/openbao tenants.tf landed in #374; the agent wiring is next),
#   • OEC enrollment follows persistence (ADR 0017 §7) — a persistent tenant enrolls, an
#     ephemeral one is exempt; base.nix enables OEC, so persistent tenants are covered.
# These attach here as they land WITHOUT changing the tenant-facing contract surface.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  t = config.krg.tenant;
  hasTenant = t != {};
  hasCompose = hasTenant && (t.interior.compose or null) != null;
  hasRepo = hasTenant && (t.interior.repo or null) != null;
  hasTemporal = hasTenant && (t.boundary.temporal or null) != null;
in {
  imports = [
    ../profiles/server.nix # the lab baseline (base + monitoring)
    ./docker.nix
    ./services/compose-stack.nix
    ./services/vault-agent.nix # krg.vaultAgent — renders the <tenant>.vm cert (ADR 0021)
  ];

  options.krg.tenant = mkOption {
    type = types.attrs;
    default = {};
    description = ''
      The `lib.mkTenant` spec for this instance — the whole returned attrset. Set it
      from the tenant flake (`krg.tenant = krg-infra.lib.mkTenant { ... };`); the module
      reads `.name`, `.boundary.sso.group`, `.interior.compose`, etc. from it. Empty
      (the default) leaves the module inert — it contributes only its baseline imports.
    '';
  };

  config = mkIf hasTenant (mkMerge [
    {
      # Baseline + identity. Hostname follows the tenant slug; the network is DHCP from
      # the Incus NAT (the platform assigns the RFC1918 address — see terraform/incus).
      krg.base = {
        enable = true;
        isVM = true; # Incus VM-type instance (the untrusted-tenant isolation tier)
      };
      krg.adminAccount = mkDefault "krg-admin"; # admins own boundary + break-glass recovery
      krg.docker.enable = true;

      networking.hostName = mkDefault t.name;
      networking.useDHCP = mkDefault true; # Incus NAT DHCP

      system.stateVersion = mkDefault "25.11";
    }

    (mkIf hasCompose (let
      tlsDir = "/run/tenant/tls";
      cn = "${t.name}.vm"; # the tenant-internal SERVER cert CN (terraform/openbao pki.tf)
      # One pki_int/issue/tenant-internal write, rendered to two files. The two renders
      # carry IDENTICAL secret args, so the agent's template engine (a consul-template
      # fork) dedups the dependency and BOTH files come from the SAME issuance — a matching
      # cert+key (a second issue would mint a non-matching key). crt = leaf + issuing CA so
      # the edge can verify the chain; key = the matching private key (ADR 0021 §2).
      # Double-quoted (not '') so nix indentation-stripping can't leak leading whitespace
      # into the rendered PEM; \n are literal newlines in the template body.
      issue = field: "{{ with secret \"pki_int/issue/tenant-internal\" \"common_name=${cn}\" }}${field}{{ end }}";

      # Temporal client-cert renders (ADR 0023 §2), added ONLY when the tenant requested
      # Temporal access (boundary.temporal). Same single-issuance dedup trick: 3 renders with
      # IDENTICAL args → one issuance → leaf/key/CA split into tls.crt/tls.key/ca.crt. CN is
      # "<name>-worker" (must be allowed in terraform/openbao temporal_client_domains). The
      # worker dials krg-prod.ucsd.edu:7233 with TLS server-name workflows.krg.ucsd.edu.
      tdir = "/run/tenant/temporal";
      tcn = "${t.name}-worker";
      tissue = field: "{{ with secret \"pki_int/issue/temporal-client\" \"common_name=${tcn}\" }}${field}{{ end }}";
      temporalRenders = optionals hasTemporal [
        {
          destination = "${tdir}/tls.crt";
          perms = "0644";
          dirPerms = "0755";
          contents = tissue "{{ .Data.certificate }}\n";
        }
        {
          destination = "${tdir}/tls.key";
          perms = "0640";
          dirPerms = "0755";
          contents = tissue "{{ .Data.private_key }}\n";
        }
        {
          destination = "${tdir}/ca.crt";
          perms = "0644";
          dirPerms = "0755";
          contents = tissue "{{ .Data.issuing_ca }}\n";
        }
      ];
    in {
      # The tenant's compose, run as a managed stack under /var/lib/krg/<name>. The
      # INTERIOR is tenant-owned: the runner ships updates via merged auto-deploy PRs
      # (ADR 0017 §8); nix only declares the stack that runs it. Ordered AFTER openbao-agent
      # so the <tenant>.vm cert is on /run before the inner Traefik starts — fail-closed if
      # bao is sealed/unreachable (the stack never starts with a missing/stale cert).
      krg.composeStacks.${t.name} = {
        composeFiles = [(toString t.interior.compose)];
        after = ["openbao-agent.service"];
        requires = ["openbao-agent.service"];
      };

      # In-instance vault-agent mints the tenant's OWN tenant-internal server cert
      # (<tenant>.vm) from its per-tenant AppRole (terraform/openbao tenants.tf grants
      # pki_int/issue/tenant-internal, scoped to this tenant) and renders cert+key to
      # /run/tenant/tls for the inner Traefik to serve. The zone edge re-encrypts and
      # verifies <tenant>.vm by chain against the fleet CA (ADR 0017 §5 / ADR 0021 §1).
      # Traefik's file provider watches these paths and hot-reloads on rotation, so no
      # reloadCommand is needed. Secret-zero (role-id + secret-id for tenant-<name>) is
      # pushed into the instance by krg-deploy at provision (ADR 0021 §3) — until that
      # lands, stage it manually; the agent fails closed without it.
      krg.vaultAgent = {
        enable = true;
        roleName = "tenant-${t.name}"; # the tofu AppRole (terraform/openbao tenants.tf)
        renders =
          [
            {
              destination = "${tlsDir}/${cn}.crt";
              perms = "0644"; # leaf + chain (not secret)
              dirPerms = "0755"; # the inner-Traefik container traverses to read the pair
              contents = issue "{{ .Data.certificate }}\n{{ .Data.issuing_ca }}\n";
            }
            {
              destination = "${tlsDir}/${cn}.key";
              perms = "0640"; # private key (inner Traefik runs as root by default)
              dirPerms = "0755";
              contents = issue "{{ .Data.private_key }}\n";
            }
          ]
          ++ temporalRenders;
      };
    }))

    # ── repo-owns-deploy runner (ADR 0022) ──────────────────────────────────────
    # A self-hosted GitHub Actions runner scoped to the tenant's repo. A merged
    # auto-deploy/* PR runs `systemctl start ${t.name}-selfupdate` on this runner, which
    # converges the instance from the tenant flake (config + the krg.composeStacks interior).
    (mkIf hasRepo (let
      repo = t.interior.repo; # "owner/name", e.g. "UCSD-E4E/fishsense-lite"
      runnerUser = "gh-runner";
      selfUpdate = "${t.name}-selfupdate";
      # Registration token pushed into the instance by krg-deploy at provision (the App
      # broker → incus file push, ADR 0022 §2/§3). The runner registers ONCE and persists
      # its own creds, so a between-deploys expiry is harmless.
      tokenFile = "/var/lib/krg/github-runner/registration-token";
      workDir = "/var/lib/${runnerUser}/work";
    in {
      # A dedicated, NON-admin user runs the tenant's CI — never krg-admin (tenant
      # workflow code must not run as the break-glass admin). Its ONLY privileged
      # capability is starting the one self-update unit below (polkit-scoped) — no docker
      # group, no sudo. Image builds/pushes belong in GitHub-hosted CI; this runner only
      # triggers the deploy.
      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        home = "/var/lib/${runnerUser}";
        createHome = true;
      };
      users.groups.${runnerUser} = {};

      systemd.tmpfiles.rules = [
        "d /var/lib/krg/github-runner 0700 root root -" # krg-deploy pushes the token here (root)
        # The runner's workDir. createHome makes the home (/var/lib/gh-runner) but NOT this
        # subdir, and the github-runners unit sandbox bind-mounts workDir — a missing dir
        # fails at namespace setup (`status=226/NAMESPACE: /var/lib/gh-runner/work: No such
        # file or directory`) before the runner ever starts. Create both so the mount lands.
        "d /var/lib/${runnerUser} 0750 ${runnerUser} ${runnerUser} -"
        "d ${workDir} 0700 ${runnerUser} ${runnerUser} -"
      ];

      services.github-runners.${t.name} = {
        enable = true;
        inherit (t) name;
        url = "https://github.com/${repo}";
        inherit tokenFile workDir;
        user = runnerUser;
        replace = true; # re-register over a stale runner of this name
        extraLabels = [t.name]; # the tenant workflow targets [self-hosted, <name>]
        extraPackages = with pkgs; [git openssh systemd coreutils]; # systemctl to trigger the switch
      };

      # Converge from the tenant flake — a root, host-context oneshot the runner triggers via
      # `systemctl start` (polkit-authorized, no sudo, runner sandbox intact — the pattern
      # krg-deploy uses for its own self-update). Rebuilds from the tenant repo's flake
      # (`.#<name>`), which brings up the config AND the krg.composeStacks interior. --refresh
      # bypasses the eval cache so a just-merged commit is picked up. (Assumes a PUBLIC tenant
      # repo; a private repo needs a fetch token — a tracked follow-up.)
      systemd.services.${selfUpdate} = {
        description = "Converge ${t.name} from ${repo} (tenant self-deploy, ADR 0022)";
        restartIfChanged = false;
        stopIfChanged = false;
        path = [pkgs.nixos-rebuild pkgs.systemd pkgs.coreutils pkgs.git pkgs.openssh config.nix.package];
        serviceConfig.Type = "oneshot";
        script = ''
          set -uo pipefail
          RUNNER=github-runner-${t.name}.service
          systemctl stop "$RUNNER" || true
          nixos-rebuild switch --flake github:${repo}#${t.name} --refresh
          rc=$?
          systemctl start "$RUNNER" || true
          exit "$rc"
        '';
      };

      # polkit MUST be on for a non-root `systemctl start` of a system unit to be
      # consulted (else systemd denies outright). Authorize ONLY runnerUser to start ONLY
      # the self-update unit — everything else still needs root.
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "${selfUpdate}.service" &&
              subject.user == "${runnerUser}") {
            return polkit.Result.YES;
          }
        });
      '';
    }))
  ]);
}
