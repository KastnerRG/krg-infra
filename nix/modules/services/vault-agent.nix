# krg.vaultAgent — render secrets from OpenBao (krg-vault) to tmpfs at runtime,
# replacing hand-placed /var/lib/krg/.../.secrets/* files.
#
# This is the keystone the repo deferred (see the "vault-agent" references in
# terraform/authentik/vault_secrets.tf and docs/openbao-bringup.md). It runs the
# OpenBao Agent (`bao agent`), authenticates with the host's AppRole, and renders
# template stanzas to files. First consumer: Guacamole's Postgres password.
#
# Mechanism: one-shot render (`exit_after_auth = true`) — the agent authenticates,
# renders every template once, and exits. Run as a systemd oneshot ordered BEFORE
# the consuming compose stack (which `requires`/`after`s it), so the stack fails
# closed if bao is sealed/unreachable (no stale or empty secrets).
#
# Re-rendering: the unit is a oneshot with RemainAfterExit, so it stays `active
# (exited)` and NOTHING re-runs it on its own. In particular a dependent stack's
# `requires=` does NOT restart an already-active unit (an earlier version of this
# comment claimed it did — it does not), and `nixos-rebuild switch` only restarts it
# when the UNIT DEFINITION changes (e.g. a nixpkgs bump moving `pkgs.openbao`), never
# because a rendered VALUE went stale. Three things re-render:
#
#   1. `krg.vaultAgent.renewal` (below) — a timer that restarts the agent once any
#      rendered CERT enters the last third of its lifetime. This is what keeps
#      short-TTL PKI leaves alive (`pki_int/issue/temporal-client` is 7d) on hosts
#      that can go weeks without a deploy — notably Incus TENANTS, which converge
#      from their own flake via `<tenant>-selfupdate` and never run deploy-nixos.sh.
#      Without it a leaf expires in place: that is the fishsense Temporal worker
#      outage of 2026-08-17 (`received fatal alert: CertificateExpired`, exactly 7d
#      after the single render); every tenant's 30d `<tenant>.vm` cert carried the
#      same fuse, just a slower one.
#   2. deploy/deploy-nixos.sh, after every fleet switch — this is why krg-prod /
#      waiter / kastner-ml never hit the above, and why tenants did.
#   3. `systemctl restart openbao-agent` by hand.
#
# A render whose consumer caches the secret in memory (a TLS cert loaded once at
# process start) must ALSO set `reloadCommand` — re-rendering alone leaves the old
# material live in the running process.
#
# Secret-zero: the agent needs a `secret_id` to authenticate — the single on-box
# bootstrap credential (root-only file, minted by the krg-deploy AppRole, which
# already holds `auth/approle/role/+/secret-id`; see terraform/openbao). The
# `role_id` is non-secret. Rendered files live on /run (tmpfs) and are recreated
# every boot, so no secret material is ever written to durable disk.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.vaultAgent;

  renderType = types.submodule {
    options = {
      destination = mkOption {
        type = types.str;
        description = "Absolute path to render the secret to (use /run/... for tmpfs).";
      };
      perms = mkOption {
        type = types.str;
        default = "0640";
        description = "File mode for the rendered file.";
      };
      dirPerms = mkOption {
        type = types.str;
        default = "0750";
        description = ''
          Mode for the render's parent dir. Defaults to 0750 (root-gated). Raise to
          0755 when the file is bind-mounted into a container that runs as a non-root
          uid and must traverse the dir to read it — the dir's own parent stays
          0750, so the host is still gated. A dir gets the MOST PERMISSIVE dirPerms
          among the renders that target it.
        '';
      };
      contents = mkOption {
        type = types.str;
        description = ''
          OpenBao Agent (consul-template) template body. KV-v2 reads use the
          `secret/data/<path>` form and fields under `.Data.data`, e.g.
          `{{ with secret "secret/data/krg-prod/authentik-managed/guacamole" }}...{{ .Data.data.db_password }}...{{ end }}`.
        '';
      };
      errorOnMissingKey = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Fail the (whole) agent render when this template's secret/field is absent.
          Defaults TRUE — the fail-closed contract: a missing secret takes the
          dependent stack down rather than starting it with an empty value (no
          silent drift). Set FALSE only for a secret that is structurally
          GENERATED AFTER this render runs and whose absence fails LOUDLY at the
          consumer (not silently) — the lone case is an Authentik OUTPOST token:
          authentik_token.key is minted in phase 3 (terraform/authentik), AFTER
          this phase-2 render, so on a from-scratch deploy the path is briefly
          empty; an empty outpost token makes the outpost visibly fail to connect
          (Admin → Outposts + login failure), and deploy/deploy-rerender-secrets.sh
          re-renders after phase 3 to converge in one run. Guard the template body
          with `{{ if .Data.data.<field> }}…{{ end }}` so a missing field yields an
          EMPTY file, not the literal `<no value>`.
        '';
      };
      reloadCommand = mkOption {
        type = types.str;
        default = "";
        description = ''
          Optional command run ONLY when this render's content CHANGES — the OpenBao
          Agent fires the template `command` on a write (a rotation), not when the
          rendered value is unchanged. Use it to reload the consumer that holds the
          secret in memory, e.g. `''${pkgs.docker}/bin/docker restart temporal-ui`,
          because Docker Compose does NOT recreate a container when only an env_file's
          CONTENTS change. The deploy re-runs the agent each switch
          (deploy/deploy-nixos.sh), so a rotated secret propagates on the next deploy.
          Wrapped `|| true` so it can never fail the fail-closed agent. Give the full
          binary path — the agent's PATH is minimal.
        '';
      };
    };
  };

  # Each template body is written to its own store file referenced via `source`
  # (avoids HCL heredoc/quote-escaping of the template syntax). `command` (run only on
  # a render CHANGE) reloads the consumer after a rotation; routed through a tiny
  # script so the reloadCommand can't break the HCL quoting and is always non-fatal.
  templateBlocks =
    concatMapStringsSep "\n" (r: ''
      template {
        source               = "${pkgs.writeText "openbao-agent-tmpl" r.contents}"
        destination          = "${r.destination}"
        perms                = "${r.perms}"
        error_on_missing_key = ${boolToString r.errorOnMissingKey}
        ${optionalString (r.reloadCommand != "") ''command = "${pkgs.writeShellScript "openbao-agent-reload" "${r.reloadCommand} || true"}"''}
      }
    '')
    cfg.renders;

  agentConfig = pkgs.writeText "openbao-agent.hcl" ''
    vault {
      address = "${cfg.vaultAddr}"
    }

    auto_auth {
      method "approle" {
        config = {
          role_id_file_path                   = "${cfg.roleIdFile}"
          secret_id_file_path                 = "${cfg.secretIdFile}"
          remove_secret_id_file_after_reading = false
        }
      }
    }

    # Fail closed: a render/auth failure exits non-zero instead of retrying
    # forever, so the dependent compose stack won't start with missing secrets.
    template_config {
      exit_on_retry_failure = true
    }

    exit_after_auth = true

    ${templateBlocks}
  '';

  # Parent dirs of every render destination (recreated each boot since /run is tmpfs).
  # Each dir takes the MOST PERMISSIVE dirPerms among the renders targeting it, so a
  # container-read dir can opt up to 0755 while everything else stays 0750. (Mode
  # strings compare lexically — "0755" > "0750" — which is the ordering we want here.)
  renderDirPairs =
    map (r: {
      dir = builtins.dirOf r.destination;
      inherit (r) dirPerms;
    })
    cfg.renders;
  renewalActive = cfg.renewal.enable && cfg.renders != [];

  # Renewal check (krg.vaultAgent.renewal). The agent is a ONE-SHOT, so a rendered PKI
  # leaf otherwise sits on /run until it expires. Walk every render destination; anything
  # that parses as an X.509 cert has its remaining life compared against its TOTAL
  # lifetime, so the window follows the issuing role's TTL instead of a hardcoded number
  # of days. Non-cert renders (KV env files, bare private keys) fail the openssl parse and
  # are skipped — no per-render "this one is a cert" flag to keep in sync. A single
  # qualifying cert restarts the agent, which re-issues every template and fires each
  # CHANGED render's reloadCommand.
  #
  # NOTE a PKI template re-renders a *fresh* cert on every agent run, so its content
  # always "changes" and its reloadCommand always fires. That is exactly why this is a
  # windowed check and not an unconditional periodic restart: an unconditional restart
  # would bounce every cert consumer on every tick.
  renewScript = pkgs.writeShellScript "openbao-agent-renew" ''
    set -uo pipefail

    openssl=${pkgs.openssl}/bin/openssl
    date=${pkgs.coreutils}/bin/date

    now=$($date +%s)
    need=0

    for f in ${concatMapStringsSep " " (r: escapeShellArg r.destination) cfg.renders}; do
      # A destination that vanished (or a render that never completed) is itself a
      # reason to re-run the agent — fail-closed consumers stay down until it does.
      if [ ! -r "$f" ]; then
        echo "renew: $f is missing or unreadable — re-rendering"
        need=1
        continue
      fi

      # Not a certificate (env file, bare private key) → skip quietly.
      nb=$($openssl x509 -in "$f" -noout -startdate 2>/dev/null) || continue
      na=$($openssl x509 -in "$f" -noout -enddate 2>/dev/null) || continue
      nbs=$($date -d "''${nb#notBefore=}" +%s 2>/dev/null) || continue
      nas=$($date -d "''${na#notAfter=}" +%s 2>/dev/null) || continue

      life=$((nas - nbs))
      [ "$life" -gt 0 ] || continue
      rem=$((nas - now))

      if [ $((rem * 100)) -lt $((life * ${toString cfg.renewal.percentRemaining})) ]; then
        echo "renew: $f has $((rem / 3600))h of $((life / 3600))h left" \
             "(under ${toString cfg.renewal.percentRemaining}%) — re-rendering"
        need=1
      fi
    done

    if [ "$need" -eq 1 ]; then
      exec ${config.systemd.package}/bin/systemctl restart openbao-agent.service
    fi

    echo "renew: every rendered cert is outside its renewal window; nothing to do"
  '';

  destDirs =
    map (d: {
      dir = d;
      perms = foldl' (acc: p:
        if p.dir == d && p.dirPerms > acc
        then p.dirPerms
        else acc) "0000"
      renderDirPairs;
    })
    (unique (map (p: p.dir) renderDirPairs));
in {
  options.krg.vaultAgent = {
    enable = mkEnableOption "OpenBao Agent secret rendering (AppRole → tmpfs)";

    roleName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = ''
        AppRole role_name this host authenticates as (terraform/openbao). The deploy
        (deploy/deploy-nixos.sh) reads this to mint + stage the host's role-id +
        secret-id before the switch, so the agent has its secret-zero. Defaults to the
        hostname — the convention the tofu AppRoles follow (e.g. waiter, kastner-ml).
      '';
    };

    vaultAddr = mkOption {
      type = types.str;
      default = "https://krg-vault.ucsd.edu:8200";
      description = "OpenBao API address. TLS is verified against the system CA store.";
    };

    roleIdFile = mkOption {
      type = types.str;
      default = "/var/lib/krg/openbao-agent/role-id";
      description = "Path to the AppRole role_id (non-secret).";
    };

    secretIdFile = mkOption {
      type = types.str;
      default = "/var/lib/krg/openbao-agent/secret-id";
      description = ''
        Path to the AppRole secret_id. Auto-staged before each switch by
        deploy/deploy-nixos.sh: krg-deploy mints a fresh secret_id via its AppRole
        and pushes it here root-only (0600). No longer hand-placed — only
        krg-deploy's OWN secret-zero is provisioned out-of-band.
      '';
    };

    renders = mkOption {
      type = types.listOf renderType;
      default = [];
      description = "Secret render specs; each renders one OpenBao template to a file.";
    };

    renewal = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Re-render before a rendered CERTIFICATE expires. The agent is a one-shot, so
          without this a PKI leaf rendered to /run lives exactly as long as its issued
          TTL and then expires in place — which is how the fishsense Temporal worker died
          7 days after its only render (see the re-rendering note at the top of this
          file). A timer inspects every render destination that parses as an X.509 cert
          and restarts the agent once a leaf is inside its renewal window; that re-issues
          EVERY template and fires each changed render's reloadCommand. A harmless no-op
          on hosts whose renders are all KV values (krg-prod's env files skip the parse),
          so it is ON by default rather than opt-in — the failure mode it prevents is
          silent right up until the outage.
        '';
      };

      onCalendar = mkOption {
        type = types.str;
        default = "hourly";
        description = ''
          systemd OnCalendar for the renewal CHECK (not the renewal itself — the check is
          a few openssl calls and re-renders nothing until a leaf is in-window). Keep it
          far below the window implied by percentRemaining.
        '';
      };

      percentRemaining = mkOption {
        type = types.ints.between 1 99;
        default = 33;
        description = ''
          Renew once less than this percent of a leaf's TOTAL lifetime (notAfter minus
          notBefore) remains. Expressed as a fraction of lifetime, not a fixed number of
          days, so the window scales with whatever TTL the issuing role carries: a 7d
          `temporal-client` leaf renews with ~2.3d of slack, a 30d `host` or
          `tenant-internal` leaf with ~10d. Both comfortably exceed a nightly
          autoUpgrade/converge cycle, so renewal never depends on a deploy landing.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # Create the AppRole credential dir (root-only). nix owns the DIR + perms;
    # the operator drops role-id/secret-id in (the secret-id is a live credential,
    # minted out-of-band by the krg-deploy role — never nix-managed content).
    systemd.tmpfiles.rules =
      map (d: "d ${d} 0700 root root -")
      (unique [(builtins.dirOf cfg.roleIdFile) (builtins.dirOf cfg.secretIdFile)]);

    systemd.services.openbao-agent = {
      description = "OpenBao Agent — render secrets from krg-vault to tmpfs";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # `bao` resolves a CLI token-helper home dir at startup; with no HOME set it
      # shells out to `sh` to expand `~`, which fails in the unit's minimal PATH
      # ("exec: sh: not found") before it ever authenticates. Give it an ephemeral
      # HOME so it skips the shell-out, and put a shell on PATH as belt-and-suspenders.
      environment.HOME = "/run/openbao-agent";
      path = [pkgs.bash];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "openbao-agent";
        # Recreate render-destination parent dirs (on /run tmpfs, wiped each boot).
        ExecStartPre = pkgs.writeShellScript "openbao-agent-mkdirs" (
          concatMapStringsSep "\n" (d: "${pkgs.coreutils}/bin/install -d -m ${d.perms} ${escapeShellArg d.dir}") destDirs
        );
        ExecStart = "${pkgs.openbao}/bin/bao agent -config=${agentConfig}";
      };
    };

    # ── renewal ────────────────────────────────────────────────────────────────
    # Gated on renders != [] so a vaultAgent host with nothing to render carries no
    # timer (and the check script's `for` loop is never built with an empty word list).
    systemd.services.openbao-agent-renew = mkIf renewalActive {
      description = "Re-render OpenBao Agent secrets when a rendered cert nears expiry";
      # network-online so the restart it triggers can actually reach bao. If bao is
      # unreachable the agent fails closed and the PREVIOUS /run files stay in place
      # (consumers keep the last-good cert) — the next tick retries, and the renewal
      # window is wide enough to absorb a long bao outage before anything expires.
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = renewScript;
      };
    };

    systemd.timers.openbao-agent-renew = mkIf renewalActive {
      description = "Periodic expiry check for OpenBao Agent cert renders";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.renewal.onCalendar;
        # Spread the fleet + tenants so they do not all hit bao on the hour.
        RandomizedDelaySec = "15m";
        # Catch up after downtime — a box off for a week must check on the way up
        # rather than wait for the next tick holding an already-expired leaf.
        Persistent = true;
      };
    };
  };
}
