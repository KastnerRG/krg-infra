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
# closed if bao is sealed/unreachable (no stale or empty secrets). To re-render
# after a rotation, restart the consuming stack (which restarts this first) or
# `systemctl restart openbao-agent`.
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
      contents = mkOption {
        type = types.str;
        description = ''
          OpenBao Agent (consul-template) template body. KV-v2 reads use the
          `secret/data/<path>` form and fields under `.Data.data`, e.g.
          `{{ with secret "secret/data/krg-prod/guacamole" }}...{{ .Data.data.db_password }}...{{ end }}`.
        '';
      };
    };
  };

  # Each template body is written to its own store file referenced via `source`
  # (avoids HCL heredoc/quote-escaping of the template syntax).
  templateBlocks =
    concatMapStringsSep "\n" (r: ''
      template {
        source               = "${pkgs.writeText "openbao-agent-tmpl" r.contents}"
        destination          = "${r.destination}"
        perms                = "${r.perms}"
        error_on_missing_key = true
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
  destDirs = unique (map (r: builtins.dirOf r.destination) cfg.renders);
in {
  options.krg.vaultAgent = {
    enable = mkEnableOption "OpenBao Agent secret rendering (AppRole → tmpfs)";

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
        Path to the AppRole secret_id — the single on-box bootstrap credential.
        Provisioned out-of-band (minted by the krg-deploy role), root-only (0400).
      '';
    };

    renders = mkOption {
      type = types.listOf renderType;
      default = [];
      description = "Secret render specs; each renders one OpenBao template to a file.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.openbao-agent = {
      description = "OpenBao Agent — render secrets from krg-vault to tmpfs";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Recreate render-destination parent dirs (on /run tmpfs, wiped each boot).
        ExecStartPre = pkgs.writeShellScript "openbao-agent-mkdirs" (
          concatMapStringsSep "\n" (d: "${pkgs.coreutils}/bin/install -d -m 0750 ${escapeShellArg d}") destDirs
        );
        ExecStart = "${pkgs.openbao}/bin/bao agent -config=${agentConfig}";
      };
    };
  };
}
