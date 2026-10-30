# Opt-in until the source API shapes and credentials pass the dry-run gate.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.krg.outlineGroupSync;
  source = lib.cleanSourceWith {
    src = ../../docker-compose/outline-group-sync;
    filter = path: _type: !(builtins.elem (builtins.baseNameOf path) ["__pycache__" ".pytest_cache" ".ruff_cache" ".venv"]);
  };
  # Content-address the locally built image: a source change must rebuild it.
  image = "krg-outline-group-sync:${builtins.baseNameOf "${source}"}";
  reload = "${config.systemd.package}/bin/systemctl try-restart --no-block outline-group-sync.service";
  environment = {
    TEMPORAL_ADDRESS = "workflows.krg.ucsd.edu:7233";
    TEMPORAL_NAMESPACE = "default";
    TEMPORAL_TLS_SERVER_NAME = "workflows.krg.ucsd.edu";
    TEMPORAL_TLS_CERT = "/tls/client.pem";
    TEMPORAL_TLS_CA = "/tls/ca.crt";
  };
  common = {
    inherit image environment;
    build.context = "${source}";
    volumes = ["/run/krg/outline-sync/tls:/tls:ro"];
    read_only = true;
    cap_drop = ["ALL"];
    security_opt = ["no-new-privileges:true"];
    stop_grace_period = "60s";
  };
  compose = pkgs.writeText "outline-group-sync.yml" (lib.generators.toYAML {} {
    services = {
      worker =
        common
        // {
          restart = "unless-stopped";
          env_file = ["/run/krg/outline-sync/api.env"];
          environment =
            environment
            // {
              AUTHENTIK_URL = "https://auth.krg.ucsd.edu/api/v3/";
              OUTLINE_URL = "https://docs.krg.ucsd.edu/api/";
              AUTHENTIK_LDAP_SOURCE = "krg-samba-ad";
              SYNC_APPLY =
                if cfg.apply
                then "true"
                else "false";
            };
        };
      schedule =
        common
        // {
          command = ["python" "worker.py" "schedule"];
          restart = "on-failure";
        };
    };
  });
in {
  options.krg.outlineGroupSync = {
    enable = lib.mkEnableOption "Temporal reconciliation of LDAP-backed Outline groups";
    apply = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Write group changes; false runs scheduled dry runs only.";
    };
  };

  config = lib.mkIf cfg.enable {
    krg.composeStacks.outline-group-sync = {
      description = "LDAP to Outline group reconciliation via Temporal";
      composeFiles = ["${compose}"];
      after = ["krg-prod.service"];
      failClosedOn = ["openbao-agent.service"];
      # Only this two-container worker stack restarts on config/cert rotation.
      recreateOnConfigChange = true;
    };
    krg.vaultAgent.renders = [
      {
        destination = "/run/krg/outline-sync/api.env";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/outline-group-sync" }}
          AUTHENTIK_TOKEN={{ .Data.data.authentik_token }}
          OUTLINE_TOKEN={{ .Data.data.outline_token }}
          {{- end }}
        '';
        reloadCommand = reload;
      }
      {
        destination = "/run/krg/outline-sync/tls/client.pem";
        perms = "0644";
        dirPerms = "0755";
        contents = ''
          {{- with secret "pki_int/issue/temporal-client" "common_name=temporal-worker" }}
          {{ .Data.certificate }}
          {{ .Data.issuing_ca }}
          {{ .Data.private_key }}
          {{- end }}
        '';
        reloadCommand = reload;
      }
      {
        destination = "/run/krg/outline-sync/tls/ca.crt";
        perms = "0644";
        dirPerms = "0755";
        contents = ''
          {{- with secret "pki_int/issue/temporal-client" "common_name=temporal-worker" }}
          {{ .Data.issuing_ca }}
          {{- end }}
        '';
        reloadCommand = reload;
      }
    ];
  };
}
