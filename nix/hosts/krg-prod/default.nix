{pkgs, ...}: let
  # Referencing the directory (not individual files) puts the entire
  # docker-compose/krg-prod/ subtree into a single Nix store path so that
  # relative symlinks and config bind-mounts below all point into the same
  # store derivation.
  composeDir = ../../docker-compose/krg-prod;
  # Guacamole is its OWN standalone stack (not include'd into the krg-prod
  # compose project) so its dependency on the OpenBao-rendered DB secret fails
  # closed for Guacamole alone — a bao outage must not take down the rest.
  guacamoleDir = ../../docker-compose/guacamole;
  # Temporal — same rationale: standalone stack so its OpenBao-rendered secrets
  # (postgres password + OIDC client secret) fail closed for Temporal alone.
  temporalDir = ../../docker-compose/temporal;
in {
  imports = [
    ../../profiles/server.nix
    ../../modules/services/vault-agent.nix
    ./hardware-configuration.nix
  ];

  # KRG lab-wide production host (the old "fabricant" services). E4E
  # project-specific services live on the separate e4e-prod host.
  krg.adminAccount = "krg-admin";

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix runs it on every
  # host) — isVM just enables the QEMU guest agent. Defense-in-depth: ports/SSH
  # are restricted in-guest AND at the Proxmox perimeter (not "firewall off").
  krg.base.isVM = true;

  networking = {
    hostName = "krg-prod";
    domain = "ucsd.edu";
    useDHCP = false;
    interfaces.ens18.ipv4.addresses = [
      {
        address = "137.110.161.106";
        prefixLength = 24;
      }
    ];
    defaultGateway = "137.110.161.1";
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];
  };

  systemd.tmpfiles.rules = [
    # ── Working directory layout under /var/lib/krg/krg-prod/ ─────────────
    # (the compose-stack module already creates /var/lib/krg/krg-prod/ and .secrets/)

    # Docker Compose `include:` resolves relative to the project directory, not
    # the compose file's Nix store path, so symlink each sub-stack into the
    # working dir where compose.yml can find them by name.
    "L+ /var/lib/krg/krg-prod/compose.authentik.yml    - - - - ${composeDir}/compose.authentik.yml"
    "L+ /var/lib/krg/krg-prod/compose.grafana.yml      - - - - ${composeDir}/compose.grafana.yml"
    "L+ /var/lib/krg/krg-prod/compose.vaultwarden.yml  - - - - ${composeDir}/compose.vaultwarden.yml"
    "L+ /var/lib/krg/krg-prod/compose.outline.yml      - - - - ${composeDir}/compose.outline.yml"
    "L+ /var/lib/krg/krg-prod/compose.mlflow.yml       - - - - ${composeDir}/compose.mlflow.yml"

    # Read-only config dirs: symlink from working dir → Nix store.
    # Docker bind-mount follows symlinks so ./prometheus resolves to the store path.
    # Use L+ (not L): plain L only creates a missing symlink and will NOT repoint an
    # existing one, so on later deploys the link would stay stuck at an OLD store path
    # and config/icon changes would never reach the host. L+ replaces it every switch.
    "L+ /var/lib/krg/krg-prod/prometheus          - - - - ${composeDir}/prometheus"
    "L+ /var/lib/krg/krg-prod/blackbox-exporter   - - - - ${composeDir}/blackbox-exporter"
    "L+ /var/lib/krg/krg-prod/grafana             - - - - ${composeDir}/grafana"

    # Loki: separate read-only config files from writable data dir
    "d  /var/lib/krg/krg-prod/loki                          0750 1000 1000 -"
    "L+ /var/lib/krg/krg-prod/loki/loki-config.yaml         - - - - ${composeDir}/loki/loki-config.yaml"
    "L+ /var/lib/krg/krg-prod/loki/config.alloy             - - - - ${composeDir}/loki/config.alloy"
    "d  /var/lib/krg/krg-prod/loki/loki-data                0750 1000 1000 -"

    # Authentik postgres: config (read-only symlinks) + data (writable)
    "d  /var/lib/krg/krg-prod/authentik                     0750 root   docker -"
    "d  /var/lib/krg/krg-prod/authentik/postgres            0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/authentik/postgres/config     - - - - ${composeDir}/authentik/postgres/config"
    "L+ /var/lib/krg/krg-prod/authentik/postgres/scripts    - - - - ${composeDir}/authentik/postgres/scripts"
    "d  /var/lib/krg/krg-prod/authentik/postgres/data       0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/media               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/data                0750 1000 1000 -"
    # App-tile icons: symlink the working dir → Nix store (docker follows it at
    # mount time, like grafana/prometheus above). Pre-create data/media/public
    # owned by the authentik uid so the read-only krg-icons bind mount
    # (compose.authentik.yml) lands inside a dir authentik can still write its
    # own media into. 2026.2 serves icons from /data/media/public/<name>.
    "L+ /var/lib/krg/krg-prod/authentik/media-icons         - - - - ${composeDir}/authentik/media-icons"
    "d  /var/lib/krg/krg-prod/authentik/data/media          0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/data/media/public   0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/certs               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/authentik/custom-templates    0750 1000 1000 -"
    # authentik_proxy runs as uid 1000 and writes its filesystem session backend
    # here (TMPDIR=/data/tmp). Must be 1000:1000 like the other authentik dirs —
    # left root:root, the proxy can't write it ("path is not writable" → "failed to
    # setup application" → forward-auth returns "no app for hostname"). Latent until
    # the outpost first started (it had been crash-looping on a missing token).
    "d  /var/lib/krg/krg-prod/authentik/proxy-tmp           0750 1000  1000 -"

    # Outline: docker.env is read-only; data dirs are writable
    "d  /var/lib/krg/krg-prod/outline                       0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/outline/docker.env            - - - - ${composeDir}/outline/docker.env"
    "d  /var/lib/krg/krg-prod/outline/outline_data          0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/outline/postgres              0750 1000 1000 -"

    # MLflow: working dir for postgres data volumes; config/Dockerfile is in the Nix store
    "d  /var/lib/krg/krg-prod/mlflow                        0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/mlflow/config                 - - - - ${composeDir}/mlflow/config"

    # Grafana, Prometheus data (writable)
    "d  /var/lib/krg/krg-prod/grafana-storage               0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/prometheus-data               0750 1000 1000 -"

    # Vaultwarden: SQLite datastore (writable; owned by the container's uid 1000)
    "d  /var/lib/krg/krg-prod/vaultwarden                   0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/vaultwarden/data              0750 1000 1000 -"

    # Traefik TLS certificate storage
    "d  /var/lib/krg/krg-prod/traefik-data                  0750 root docker -"
    "d  /var/lib/krg/krg-prod/traefik-data/letsencrypt      0750 root docker -"

    "d  /var/lib/krg/e4e-roster                             0750 root docker -"

    # Guacamole (standalone stack). The compose-stack module creates the working
    # dir + .secrets/; here we just symlink the committed DB schema into it so the
    # postgres init mount (./initdb) resolves to the Nix store. Postgres data is a
    # docker-managed named volume (no uid juggling). The DB secret is rendered to
    # /run by krg.vaultAgent, not a .secrets/ file.
    "L+ /var/lib/krg/guacamole/initdb                       - - - - ${guacamoleDir}/initdb"
  ];

  environment.systemPackages = with pkgs; [openbao];
  environment.variables.VAULT_ADDR = "https://krg-vault.ucsd.edu:8200";

  # TODO Automate secrets
  # krg-prod runs as a single compose project (compose.yml uses `include:` to
  # bring in authentik, grafana, mlflow, and outline stacks).
  #
  # Secrets required in /var/lib/krg/krg-prod/.secrets/ before starting:
  #   authentik_postgres_admin_password.txt
  #   authentik_admin_password.env      (AUTHENTIK_SECRET_KEY=... AUTHENTIK_POSTGRESQL__PASSWORD=...)
  #   authentik_traefik_token.env
  #   gf_admin_password.txt
  #   outline_secrets.env               (SECRET_KEY, UTILS_SECRET, OIDC_CLIENT_SECRET, DATABASE_URL, ...)
  #   mlflow.env                        (POSTGRES_PASSWORD, OIDC_* vars)
  #   vaultwarden.env                   (ADMIN_TOKEN=<argon2 hash>, SSO_CLIENT_SECRET=<from OpenBao>)
  #     ADMIN_TOKEN:      vaultwarden hash   (or argon2 a strong password) — gates /admin
  #     SSO_CLIENT_SECRET: bao kv get -field=client_secret secret/krg-prod/vaultwarden-oidc
  #
  # Temporal (separate stack, below) takes NO .secrets/ file — its postgres password
  # and OIDC client secret are rendered from OpenBao to /run by krg.vaultAgent, same
  # as Guacamole.
  #
  # Also create /var/lib/krg/krg-prod/.env with:
  #   USER_ID=<UID of the account that owns the working directory>
  #   GROUP_ID=<GID of the account that owns the working directory>
  #
  # Guacamole (separate stack) takes NO .secrets/ file — its Postgres password is
  # rendered from OpenBao to /run by krg.vaultAgent (below). The only on-box secret
  # is the AppRole secret-id under /var/lib/krg/openbao-agent/ (see that block).
  krg.composeStacks.krg-prod = {
    description = "KRG production (lab-wide) stack — Traefik + Authentik + Grafana + services";
    composeFiles = ["${composeDir}/compose.yml"];
    workingDirectory = "/var/lib/krg/krg-prod";
    # External networks declared in compose.yml and compose.grafana.yml
    networks = ["traefik_proxy" "authentik" "prometheus_network"];
  };

  # E4E Roster V3 — source lives at /var/lib/krg/e4e-roster (git-managed, not nix store).
  # Bootstrap: git clone https://github.com/UCSD-E4E/E4E-Roster-V3.git /var/lib/krg/e4e-roster
  # then create /var/lib/krg/e4e-roster/.env from Vault (see terraform/authentik/).
  # Update: git -C /var/lib/krg/e4e-roster pull && systemctl restart e4e-roster
  # Secrets in Vault: secret/krg-prod/roster (db_password, session_secret)
  #                   secret/krg-prod/roster-oidc (client_id, client_secret)
  #                   secret/krg-prod/roster-ldap (bind_password) — generated by Terraform; use when creating svc_roster in AD
  # GitHub + Slack integration pending (see GitHub issue #74).
  krg.composeStacks.e4e-roster = {
    description = "E4E Roster V3 — backend + postgres";
    composeFiles = ["/var/lib/krg/e4e-roster/docker-compose.yml"];
    workingDirectory = "/var/lib/krg/e4e-roster";
    networks = ["traefik_proxy"];
  };

  # Guacamole — remote-desktop gateway at remote.krg.ucsd.edu. Standalone stack
  # (own systemd service) so the OpenBao dependency is scoped to Guacamole alone.
  # after/requires openbao-agent: the DB password is rendered to /run BEFORE this
  # starts, and the stack fails closed if bao is sealed/unreachable. The `authentik`
  # forward-auth middleware (krg-prod stack) + Guacamole's own OIDC are the two gates.
  krg.composeStacks.guacamole = {
    description = "Apache Guacamole — remote-desktop gateway (guacd + webapp + postgres)";
    composeFiles = ["${guacamoleDir}/compose.guacamole.yml"];
    workingDirectory = "/var/lib/krg/guacamole";
    networks = ["traefik_proxy"];
    after = ["openbao-agent.service"];
    requires = ["openbao-agent.service"];
  };

  # Temporal — lab-wide workflow engine at workflows.krg.ucsd.edu. Standalone stack
  # (own systemd service) so its OpenBao dependency is scoped to Temporal alone, same
  # as Guacamole. after/requires openbao-agent: the postgres password + OIDC client
  # secret are rendered to /run BEFORE this starts, and the stack fails closed if bao
  # is sealed/unreachable. Joins prometheus_network too so prometheus can scrape the
  # server's metrics at temporal:8000.
  krg.composeStacks.temporal = {
    description = "Temporal — workflow engine (server + UI + postgres)";
    composeFiles = ["${temporalDir}/compose.temporal.yml"];
    workingDirectory = "/var/lib/krg/temporal";
    networks = ["traefik_proxy" "prometheus_network"];
    after = ["openbao-agent.service"];
    requires = ["openbao-agent.service"];
  };

  # OpenBao Agent: render bao secrets to tmpfs for the standalone stacks (Guacamole's
  # Postgres password; Temporal's Postgres password + OIDC client secret). This was
  # the repo's first bao-rendered secret (the vault-agent keystone). Bootstrap (the
  # ONE on-box secret) — minted by the krg-deploy AppRole, root-only 0400:
  #   /var/lib/krg/openbao-agent/role-id     (non-secret; from `tofu output krg_prod_role_id`)
  #   /var/lib/krg/openbao-agent/secret-id   (secret; `bao write -f auth/approle/role/krg-prod/secret-id`)
  # secret/krg-prod/guacamole {db_password} is generated + stored by
  # terraform/authentik/guacamole_secrets.tf. krg-prod's policy already reads
  # secret/data/krg-prod/* (terraform/openbao/main.tf).
  krg.vaultAgent = {
    enable = true;
    # TWO env files, same value — the webapp and postgres MUST NOT share one.
    # `POSTGRES_PASSWORD` is a *legacy* Guacamole env var (the postgres container
    # needs it; the webapp uses `POSTGRESQL_PASSWORD`). If the webapp sees both,
    # the image's legacy-variable migration fires and leaves the effective
    # postgresql-password EMPTY → "SCRAM ... password is an empty string". So the
    # webapp gets web.env (POSTGRESQL_PASSWORD only) and postgres gets db.env
    # (POSTGRES_PASSWORD only).
    renders = [
      {
        destination = "/run/krg/guacamole/web.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/guacamole" }}
          POSTGRESQL_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/guacamole/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/guacamole" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      # Temporal — postgres password (secret/krg-prod/temporal {db_password}, generated
      # by terraform/authentik/temporal_secrets.tf) + OIDC client secret
      # (secret/krg-prod/temporal-oidc {client_secret}, minted by Authentik in
      # vault_secrets.tf). One var per file so no image sees a var it doesn't own.
      {
        destination = "/run/krg/temporal/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/temporal" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/temporal/server.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/temporal" }}
          POSTGRES_PWD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/temporal/ui.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/temporal-oidc" }}
          TEMPORAL_AUTH_CLIENT_SECRET={{ .Data.data.client_secret }}
          {{- end }}
        '';
      }
    ];
  };

  # Provide the OEC installer archive path once the file is available locally.
  # krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  system.stateVersion = "25.11";
}
