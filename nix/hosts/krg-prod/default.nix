{pkgs, ...}: let
  # Referencing the directory (not individual files) puts the entire
  # docker-compose/krg-prod/ subtree into a single Nix store path so that
  # relative symlinks and config bind-mounts below all point into the same
  # store derivation.
  composeDir = ../../docker-compose/krg-prod;
  # The prometheus config dir as its OWN store path (hashed only on prometheus/*),
  # so Prometheus is recreated on deploy only when ITS config changes — not on
  # every krg-prod change. Bind-mounted into the prometheus container by store path
  # (compose.grafana.yml ${PROM_CONFIG_DIR}) so config edits actually go live.
  promConfig = ../../docker-compose/krg-prod/prometheus;
in {
  imports = [
    ../../profiles/services.nix
    ../../modules/services/vault-agent.nix
    ./hardware-configuration.nix
  ];

  # KRG lab-wide production host (the old "fabricant" services). E4E
  # project-specific services live on the separate e4e-prod host.
  krg.adminAccount = "krg-admin";

  # Put the break-glass admin in the docker group on this host so it can drive
  # the compose stacks (docker compose ps/logs/restart) without sudo. Merges with
  # the ["wheel"] set in users/admin.nix (listOf concatenates across definitions).
  # NOTE: docker group membership is effectively root on the host — fine here since
  # krg-admin is already an unrestricted-sudo wheel account anyway.
  krg.users.users.krg-admin.groups = ["docker"];

  # AD domain member — verified joined 2026-06-18 (`getent Administrator` resolves).
  # Explicit marker; base.nix already defaults krg.adClient.enable on. Login stays
  # Domain-Admins-only (the base default allowedGroups).
  krg.adClient.enable = true;

  # Proxmox VM. The in-guest NixOS firewall stays ON (base.nix runs it on every
  # host) — isVM just enables the QEMU guest agent. Defense-in-depth: ports/SSH
  # are restricted in-guest AND at the Proxmox perimeter (not "firewall off").
  krg.base.isVM = true;

  # krg-prod hosts Prometheus (in a container) AND its own node_exporter (on the
  # host's 0.0.0.0:9100). The container scrapes the host via host.docker.internal
  # (compose.grafana.yml + prometheus.yml), arriving from a docker-bridge source —
  # NOT the monitoringSourceIp that node-exporter.nix's monitoringPorts rule allows.
  # Open 9100 to the docker private range so the self-scrape lands. RFC1918 docker
  # nets never appear on the external interface, so this doesn't widen real exposure.
  krg.firewall.sourcedPorts = [
    {
      port = 9100;
      sources = ["172.16.0.0/12"];
    }
  ];

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
    "L+ /var/lib/krg/krg-prod/compose.guacamole.yml    - - - - ${composeDir}/compose.guacamole.yml"
    "L+ /var/lib/krg/krg-prod/compose.temporal.yml     - - - - ${composeDir}/compose.temporal.yml"
    "L+ /var/lib/krg/krg-prod/compose.outline.yml      - - - - ${composeDir}/compose.outline.yml"
    "L+ /var/lib/krg/krg-prod/compose.mlflow.yml       - - - - ${composeDir}/compose.mlflow.yml"
    "L+ /var/lib/krg/krg-prod/compose.fleet.yml        - - - - ${composeDir}/compose.fleet.yml"

    # Read-only config dirs: symlink from working dir → Nix store.
    # Docker bind-mount follows symlinks so ./blackbox-exporter resolves to the store
    # path. Use L+ (not L): plain L only creates a missing symlink and will NOT
    # repoint an existing one, so on later deploys the link would stay stuck at an
    # OLD store path and config/icon changes would never reach the host. L+ replaces
    # it every switch.
    #
    # NOTE: prometheus is NOT here — it's bind-mounted by store path via
    # PROM_CONFIG_DIR (the systemd Environment below) so the container is recreated
    # when prometheus.yml changes. A symlinked working-dir mount can't do that: docker
    # resolves the symlink at container-create time, so repointing it leaves the
    # RUNNING container on the old config until something force-recreates it. The same
    # caveat applies to ./blackbox-exporter + ./grafana below (rarely-changed config;
    # left as-is — apply the PROM_CONFIG_DIR trick to them if they start drifting).
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

    # Outline: docker.env is read-only; the app data dir is a writable bind mount
    # (the outline app runs as uid 1000, matching this dir). Postgres data is NOT here
    # — it's a docker named volume (outline_postgres_data) so postgres:18's uid-999
    # user owns it; a 1000-owned bind mount made postgres exit 1 ("mkdir … Permission
    # denied"). See compose.outline.yml.
    "d  /var/lib/krg/krg-prod/outline                       0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/outline/docker.env            - - - - ${composeDir}/outline/docker.env"
    "d  /var/lib/krg/krg-prod/outline/outline_data          0750 1000 1000 -"

    # MLflow: working dir for postgres data volumes; config/Dockerfile + the postgres
    # initdb scripts are in the Nix store (docker follows the symlinks at mount time).
    "d  /var/lib/krg/krg-prod/mlflow                        0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/mlflow/config                 - - - - ${composeDir}/mlflow/config"
    "L+ /var/lib/krg/krg-prod/mlflow/initdb                 - - - - ${composeDir}/mlflow/initdb"

    # Fleet (ADR 0012): read-only non-secret config from the store; MySQL data is
    # writable and owned by the mysql:8.4 image's uid (999). The fleet/ dir itself is
    # root:docker like the other config parents. Secrets render to /run via krg.vaultAgent.
    "d  /var/lib/krg/krg-prod/fleet                         0750 root   docker -"
    "L+ /var/lib/krg/krg-prod/fleet/fleet.env               - - - - ${composeDir}/fleet/fleet.env"
    "d  /var/lib/krg/krg-prod/fleet/mysql                   0750 999  999  -"

    # Grafana, Prometheus data (writable)
    "d  /var/lib/krg/krg-prod/grafana-storage               0750 1000 1000 -"
    # Prometheus is the odd one out: unlike grafana/loki (which we pin to uid 1000),
    # the prom/prometheus image runs as its built-in `nobody` (65534) and has NO
    # `user:` line in compose.grafana.yml. Owning this dir 1000:1000 left nobody
    # unable to traverse it (0750) → "open data/queries.active: permission denied"
    # → panic on every start → crash loop → all Prometheus-backed dashboards "No
    # data". Own it (and thus the existing 65534 TSDB under ./data) as 65534 to
    # match the container user. Do NOT add `user: '1000'` to the service instead —
    # that would orphan the on-disk TSDB (already 65534) the other direction.
    "d  /var/lib/krg/krg-prod/prometheus-data               0750 65534 65534 -"

    # Vaultwarden: SQLite datastore (writable; owned by the container's uid 1000)
    "d  /var/lib/krg/krg-prod/vaultwarden                   0750 1000 1000 -"
    "d  /var/lib/krg/krg-prod/vaultwarden/data              0750 1000 1000 -"

    # Traefik TLS certificate storage
    "d  /var/lib/krg/krg-prod/traefik-data                  0750 root docker -"
    "d  /var/lib/krg/krg-prod/traefik-data/letsencrypt      0750 root docker -"

    "d  /var/lib/krg/e4e-roster                             0750 root docker -"

    # Guacamole: symlink its committed DB schema dir into the krg-prod working dir
    # so the postgres init mount (./guacamole/initdb) resolves to the Nix store.
    # Postgres data is a docker-managed named volume; the DB secret is rendered to
    # /run by krg.vaultAgent. (Temporal needs no working-dir symlink — its only
    # mounts are docker volumes + /run-rendered env files.)
    "L+ /var/lib/krg/krg-prod/guacamole                     - - - - ${composeDir}/guacamole"
  ];

  environment.systemPackages = with pkgs; [openbao];
  environment.variables.VAULT_ADDR = "https://krg-vault.ucsd.edu:8200";

  # krg-prod runs as a single compose project (compose.yml uses `include:` to
  # bring in authentik, grafana, mlflow, and outline stacks).
  #
  # Authentik + Grafana + Vaultwarden secrets are now rendered from OpenBao to
  # /run (tmpfs) by krg.vaultAgent (below) — no .secrets/ files for those three.
  # Because they live in this single compose project, the whole stack `requires`
  # openbao-agent and fails closed if bao is sealed/unreachable at boot (the same
  # contract Guacamole already has). See krg.vaultAgent for the render list and
  # docs/openbao-bringup.md "Seed the krg-prod stack secrets" for the one-time
  # seeding of the LIVE values (SECRET_KEY, DB passwords, admin token) — these are
  # seeded at their current values, NOT regenerated. (BOTH outpost tokens — proxy
  # and LDAP — are NOT hand-seeded: terraform/authentik/outpost_tokens.tf mints them
  # and writes them under the authentik-managed/* glob.)
  #
  # Guacamole + Temporal are include'd into this project (compose.yml) and also take
  # NO .secrets/ file — their Postgres passwords and Temporal's OIDC client secret
  # render from OpenBao to /run by krg.vaultAgent, alongside the others.
  #
  # MLflow, Outline, and Fleet are on vault-agent too (renders /run/krg/mlflow/{db,mlflow}.env,
  # /run/krg/outline/{db,outline}.env, and /run/krg/fleet/{db,server}.env from
  # terraform/secrets-generated values) — none take a .secrets/ file.
  #
  # There are NO hand-placed /var/lib/krg/krg-prod/.secrets/ files anymore — every stack
  # secret renders from OpenBao to /run via krg.vaultAgent (below).
  #
  # Also create /var/lib/krg/krg-prod/.env with:
  #   USER_ID=<UID of the account that owns the working directory>
  #   GROUP_ID=<GID of the account that owns the working directory>
  #
  # The only on-box secret material is the AppRole secret-id under
  # /var/lib/krg/openbao-agent/ (see the krg.vaultAgent block).
  krg.composeStacks.krg-prod = {
    description = "KRG production (lab-wide) stack — Traefik + Authentik + Grafana + services";
    composeFiles = ["${composeDir}/compose.yml"];
    workingDirectory = "/var/lib/krg/krg-prod";
    # External networks declared in compose.yml and compose.grafana.yml
    networks = ["traefik_proxy" "authentik" "prometheus_network"];
    # Authentik/Grafana/Vaultwarden secrets render to /run BEFORE this starts, so
    # the stack fails closed (no stale/empty secrets) if bao is down. This couples
    # the lab's ingress (Traefik) + SSO (Authentik) to krg-vault being unsealed at
    # boot — the deliberate cost of /run-only (never-on-durable-disk) secrets.
    after = ["openbao-agent.service"];
    requires = ["openbao-agent.service"];
  };

  # Expose the prometheus config store path to `docker compose` for ${PROM_CONFIG_DIR}
  # interpolation in compose.grafana.yml. Set on the SERVICE ENVIRONMENT (not via the
  # stack's --env-file) on purpose: --env-file would shadow the working-dir .env the
  # other stacks rely on for ${USER_ID}/${OIDC_*}/… — the service environment merges
  # ON TOP of .env instead. When promConfig changes, this Environment line changes, so
  # nixos-rebuild restarts krg-prod.service and `up -d` recreates Prometheus with the
  # fresh config; when it doesn't change, the unit is stable and nothing restarts.
  systemd.services.krg-prod.environment.PROM_CONFIG_DIR = "${promConfig}";

  # E4E Roster V3 — source lives at /var/lib/krg/e4e-roster (git-managed, not nix store).
  # Bootstrap: git clone https://github.com/UCSD-E4E/E4E-Roster-V3.git /var/lib/krg/e4e-roster
  # then create /var/lib/krg/e4e-roster/.env from Vault (see terraform/authentik/).
  # Update: git -C /var/lib/krg/e4e-roster pull && systemctl restart e4e-roster
  # Secrets in Vault: secret/krg-prod/authentik-managed/roster (db_password, session_secret)
  #                   secret/krg-prod/authentik-managed/roster-oidc (client_id, client_secret)
  #                   secret/krg-prod/authentik-managed/roster-ldap (bind_password) — generated by Terraform; use when creating svc_roster in AD
  # GitHub + Slack integration pending (see GitHub issue #74).
  krg.composeStacks.e4e-roster = {
    description = "E4E Roster V3 — backend + postgres";
    composeFiles = ["/var/lib/krg/e4e-roster/docker-compose.yml"];
    workingDirectory = "/var/lib/krg/e4e-roster";
    networks = ["traefik_proxy"];
  };

  # Guacamole (remote.krg.ucsd.edu) and Temporal (workflows.krg.ucsd.edu) are no
  # longer separate krg.composeStacks — they're include'd into the krg-prod project
  # (compose.yml) and share its single openbao-agent dependency. See compose.yml.

  # OpenBao Agent: render secrets from bao to tmpfs (/run). The keystone the repo
  # deferred — consumers: Guacamole + Temporal (Postgres passwords + Temporal's OIDC
  # client secret) and the Authentik / Grafana / Vaultwarden secrets that used to
  # live in .secrets/. Bootstrap (the ONE on-box secret) — minted by the krg-deploy
  # AppRole, root-only 0400:
  #   /var/lib/krg/openbao-agent/role-id     (non-secret; from `tofu output krg_prod_role_id`)
  #   /var/lib/krg/openbao-agent/secret-id   (secret; `bao write -f auth/approle/role/krg-prod/secret-id`)
  # krg-prod's policy already reads secret/data/krg-prod/* (terraform/openbao/main.tf),
  # so none of these paths need a policy change. The agent renders ALL of them in
  # one oneshot — if any path is unseeded it exits non-zero (error_on_missing_key)
  # and the krg-prod stack fails closed, so seed everything in
  # docs/openbao-bringup.md before deploying.
  krg.vaultAgent = {
    enable = true;
    renders = [
      # ── Guacamole Postgres password ──────────────────────────────────────────
      # TWO env files, same value — the webapp and postgres MUST NOT share one.
      # `POSTGRES_PASSWORD` is a *legacy* Guacamole env var (the postgres container
      # needs it; the webapp uses `POSTGRESQL_PASSWORD`). If the webapp sees both,
      # the image's legacy-variable migration fires and leaves the effective
      # postgresql-password EMPTY → "SCRAM ... password is an empty string". So the
      # webapp gets web.env (POSTGRESQL_PASSWORD only) and postgres gets db.env
      # (POSTGRES_PASSWORD only).
      {
        destination = "/run/krg/guacamole/web.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/guacamole" }}
          POSTGRESQL_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/guacamole/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/guacamole" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      # Temporal — postgres password (secret/krg-prod/authentik-managed/temporal {db_password},
      # generated by terraform/authentik/temporal_secrets.tf) + OIDC client secret
      # (secret/krg-prod/authentik-managed/temporal-oidc {client_secret}, minted by Authentik
      # in vault_secrets.tf). One var per file so no image sees a var it doesn't own.
      {
        destination = "/run/krg/temporal/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/temporal" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/temporal/server.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/temporal" }}
          POSTGRES_PWD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      {
        destination = "/run/krg/temporal/ui.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/temporal-oidc" }}
          TEMPORAL_AUTH_CLIENT_SECRET={{ .Data.data.client_secret }}
          {{- end }}
        '';
        # OIDC secret rotates → reload temporal-ui so it picks up the new env (Compose
        # won't recreate it on an env-content change). Fires only when this render
        # actually changes; deploy/deploy-nixos.sh re-runs the agent each switch.
        reloadCommand = "${pkgs.docker}/bin/docker restart temporal-ui";
      }

      # Temporal frontend mTLS (the lab-internal CA in terraform/openbao/pki.tf).
      # The gRPC frontend on :7233 presents this SERVER cert and REQUIRES a client
      # cert; temporal-ui presents the CLIENT cert below. See docs/temporal-mtls.md
      # for the full design + the on-box validation gates (this is unvalidated).
      #
      # 0644 + the dir stays 0750 root (vault-agent's ExecStartPre): the files are
      # bind-mounted into the container and read by the temporal/ui process (uid
      # 1000), not the root compose CLI — same rationale as the grafana/authentik
      # secrets above. The private key sits in /run (tmpfs), never durable disk.
      #
      # CERT+KEY GO IN ONE FILE on purpose: each `pki_int/issue/...` call mints a
      # fresh keypair, so splitting cert and key across two render blocks could
      # pair a cert with a DIFFERENT issuance's key. One combined PEM (Go's
      # tls.LoadX509KeyPair reads cert+key from the same file) makes the pair
      # atomic. TEMPORAL_TLS_FRONTEND_CERT and _KEY both point at frontend.pem.
      {
        destination = "/run/krg/temporal/tls/frontend.pem";
        perms = "0644";
        dirPerms = "0755"; # container (uid 1000) must traverse to read; parent /run/krg/temporal stays 0750
        contents = ''
          {{- with secret "pki_int/issue/temporal-frontend" "common_name=temporal" "alt_names=temporal.krg.ucsd.edu,workflows.krg.ucsd.edu" }}
          {{ .Data.certificate }}
          {{ .Data.issuing_ca }}
          {{ .Data.private_key }}
          {{- end }}
        '';
      }
      # Trust anchor: the intermediate CA. Serves as BOTH the frontend's client-CA
      # (verifying caller certs) and the UI's server-CA (verifying the frontend).
      # issuing_ca off the same issuance — identical regardless of the leaf.
      {
        destination = "/run/krg/temporal/tls/ca.crt";
        perms = "0644";
        dirPerms = "0755";
        contents = ''
          {{- with secret "pki_int/issue/temporal-frontend" "common_name=temporal" "alt_names=temporal.krg.ucsd.edu,workflows.krg.ucsd.edu" }}
          {{ .Data.issuing_ca }}
          {{- end }}
        '';
      }
      # temporal-ui's CLIENT cert (cert+key in one PEM, same atomicity rationale).
      {
        destination = "/run/krg/temporal/tls/ui-client.pem";
        perms = "0644";
        dirPerms = "0755";
        contents = ''
          {{- with secret "pki_int/issue/temporal-client" "common_name=temporal-ui" }}
          {{ .Data.certificate }}
          {{ .Data.private_key }}
          {{- end }}
        '';
      }

      # ── Authentik ────────────────────────────────────────────────────────────
      # Postgres superuser password — consumed as the `authentik_postgres_admin_password`
      # docker secret (a bare-value file, no KEY=). Used by postgres_authentik's
      # POSTGRES_PASSWORD_FILE. LIVE value: seeded from the running DB, not rotated.
      {
        destination = "/run/krg/krg-prod/authentik-postgres-admin-password";
        # 0644 (not 0640): consumed as a docker `secrets: file:` which is bind-mounted
        # INTO the container and read by the postgres process (uid 1000), not by the
        # root compose CLI. Must be world-readable so uid 1000 can read it; the parent
        # /run/krg/krg-prod dir stays 0750 root, so the host is still gated.
        perms = "0644";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik" }}{{ .Data.data.postgres_admin_password }}{{ end }}
        '';
      }
      # SECRET_KEY (signs sessions/tokens) + the authentik DB-role password.
      # env_file for authentik_server/worker/proxy AND the postgres init script.
      # Both LIVE: rotating SECRET_KEY invalidates sessions; rotating the role
      # password breaks the running DB role.
      {
        destination = "/run/krg/krg-prod/authentik.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik" }}
          AUTHENTIK_SECRET_KEY={{ .Data.data.secret_key }}
          AUTHENTIK_POSTGRESQL__PASSWORD={{ .Data.data.postgresql_password }}
          {{- end }}
        '';
      }
      # Proxy outpost token — consumed by the authentik_proxy container
      # (forward-auth for guacamole/fishsense). MINTED IN IaC by
      # terraform/authentik/outpost_tokens.tf (same pattern as the LDAP outpost
      # below); written to secret/krg-prod/authentik-managed/proxy-outpost-token.
      # errorOnMissingKey = false + the `if` guard + reloadCommand for the same
      # reason as the LDAP render: the token is generated in phase 3, after this
      # phase-2 render. See outpost_tokens.tf for the one-time cutover note (the old
      # pre-glob path secret/krg-prod/authentik-outpost-token is now orphaned).
      {
        destination = "/run/krg/krg-prod/authentik-outpost-token.env";
        perms = "0640";
        errorOnMissingKey = false;
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/proxy-outpost-token" }}
          {{- if .Data.data.token }}
          AUTHENTIK_TOKEN={{ .Data.data.token }}
          {{- end }}
          {{- end }}
        '';
        reloadCommand = "${pkgs.docker}/bin/docker restart authentik_proxy";
      }

      # LDAP outpost token — consumed by the authentik_ldap container
      # (compose.authentik.yml) so PVE's LDAP realm has something to bind against.
      # MINTED IN IaC: terraform/authentik/outpost_tokens.tf creates an api token for
      # the outpost's service account and writes it here (no manual "View token").
      #
      # errorOnMissingKey = false — the ONE non-fail-closed render on krg-prod. The
      # token is generated in phase 3, AFTER this phase-2 render, so on a from-scratch
      # deploy this path is briefly empty; an empty AUTHENTIK_TOKEN makes the outpost
      # fail LOUDLY (offline in Admin → Outposts, PVE bind fails) — never silently
      # wrong — and deploy/deploy-rerender-secrets.sh re-renders krg-prod after phase 3
      # so it converges in one run. The `if` guard renders an EMPTY file (not the
      # literal `<no value>`) while the token is absent, so the compose env_file still
      # exists and the stack comes up. Steady state (token present) is identical to
      # fail-closed. The reloadCommand restarts the outpost when the token first lands
      # / rotates (Compose won't recreate it on an env-content change). See
      # docs/proxmox-auth.md and outpost_tokens.tf for the full rationale.
      {
        destination = "/run/krg/krg-prod/authentik-ldap-outpost-token.env";
        perms = "0640";
        errorOnMissingKey = false;
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/ldap-outpost-token" }}
          {{- if .Data.data.token }}
          AUTHENTIK_TOKEN={{ .Data.data.token }}
          {{- end }}
          {{- end }}
        '';
        reloadCommand = "${pkgs.docker}/bin/docker restart authentik_ldap";
      }

      # ── Grafana ──────────────────────────────────────────────────────────────
      # Admin password — the `grafana_e4eadmin_password` docker secret (bare value).
      # Same path the terraform/grafana provider authenticates with (field `password`).
      {
        destination = "/run/krg/krg-prod/grafana-admin-password";
        # 0644: docker `secrets: file:` read by the grafana process (uid 1000), same
        # rationale as authentik-postgres-admin-password above (dir stays 0750 root).
        perms = "0644";
        contents = ''
          {{- with secret "secret/data/krg-prod/grafana-admin" }}{{ .Data.data.password }}{{ end }}
        '';
      }

      # ── Vaultwarden ──────────────────────────────────────────────────────────
      # ADMIN_TOKEN (argon2 hash; gates /admin) is a LIVE seeded value; the OIDC
      # client secret comes from the authentik-generated vaultwarden-oidc path.
      # NB: this env file is consumed by docker compose via `env_file`, and
      # compose INTERPOLATES env_file values — a literal `$` (the argon2 PHC
      # string is full of them: `$argon2id$v=19$m=...`) is read as a variable
      # reference and stripped, so the container would receive a hash with every
      # `$` gone and reject every admin login. Double each `$` -> `$$` here; the
      # OpenBao value stays a clean single-`$` hash, and compose collapses `$$`
      # back to `$` so the container gets the intact hash. Same guard on the OIDC
      # secret in case Authentik ever mints one containing `$`.
      {
        destination = "/run/krg/krg-prod/vaultwarden.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/vaultwarden" }}
          ADMIN_TOKEN={{ .Data.data.admin_token | replaceAll "$" "$$" }}
          {{- end }}
          {{- with secret "secret/data/krg-prod/authentik-managed/vaultwarden-oidc" }}
          SSO_CLIENT_SECRET={{ .Data.data.client_secret | replaceAll "$" "$$" }}
          {{- end }}
        '';
        # The OIDC client_secret rotates → reload vaultwarden to pick up the new env.
        # (ADMIN_TOKEN above is operator-seeded and stable; a client_secret rotation is
        # the only change that fires this.) Fires only on an actual render change.
        reloadCommand = "${pkgs.docker}/bin/docker restart vaultwarden";
      }

      # ── MLflow ─────────────────────────────────────────────────────────────────
      # All MLflow secrets are GENERATED by terraform/secrets (mlflow.tf) — a fresh
      # bring-up, so nothing is operator-seeded. db_password + secret_key live at
      # authentik-managed/mlflow; the OIDC client_secret at authentik-managed/mlflow-oidc.
      #
      # Postgres password — its own file (the postgres image must not see a var it
      # doesn't own). The mlflow + mlflow_auth databases share the one role.
      {
        destination = "/run/krg/mlflow/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/mlflow" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      # MLflow server env: the two password-bearing connection URIs (the Dockerfile
      # expands MLFLOW_BACKEND_STORE_URI into --backend-store-uri and reads
      # OIDC_USERS_DB_URI directly), the Flask SECRET_KEY, and the OIDC client secret.
      # The DB password is alphanumeric (terraform/secrets special=false), so no URL
      # encoding and no compose `$`-interpolation hazard.
      {
        destination = "/run/krg/mlflow/mlflow.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/mlflow" }}
          MLFLOW_BACKEND_STORE_URI=postgresql://mlflow:{{ .Data.data.db_password }}@mlflow_postgres:5432/mlflow
          OIDC_USERS_DB_URI=postgresql://mlflow:{{ .Data.data.db_password }}@mlflow_postgres:5432/mlflow_auth
          SECRET_KEY={{ .Data.data.secret_key }}
          {{- end }}
          {{- with secret "secret/data/krg-prod/authentik-managed/mlflow-oidc" }}
          OIDC_CLIENT_SECRET={{ .Data.data.client_secret }}
          {{- end }}
        '';
      }

      # ── Outline ────────────────────────────────────────────────────────────────
      # All Outline secrets are GENERATED by terraform/secrets (outline.tf) — a fresh
      # bring-up, so nothing is operator-seeded. db_password + secret_key + utils_secret
      # live at authentik-managed/outline; the OIDC client_secret at
      # authentik-managed/outline-oidc.
      #
      # Postgres password — its own file (the postgres image must not see a var it
      # doesn't own); outline_postgres uses it as POSTGRES_PASSWORD for the outline_user
      # role at first init (never rotate — outline.tf guards that).
      {
        destination = "/run/krg/outline/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/outline" }}
          POSTGRES_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      # Outline server env: the password-bearing DATABASE_URL, the SECRET_KEY /
      # UTILS_SECRET cookie/token signers (hex-32 from outline.tf), and the OIDC client
      # secret. db_password is alphanumeric (special=false), so no URL-encoding in the
      # connection string and no compose `$`-interpolation hazard.
      {
        destination = "/run/krg/outline/outline.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/outline" }}
          DATABASE_URL=postgres://outline_user:{{ .Data.data.db_password }}@outline_postgres:5432/outline
          SECRET_KEY={{ .Data.data.secret_key }}
          UTILS_SECRET={{ .Data.data.utils_secret }}
          {{- end }}
          {{- with secret "secret/data/krg-prod/authentik-managed/outline-oidc" }}
          OIDC_CLIENT_SECRET={{ .Data.data.client_secret }}
          {{- end }}
        '';
      }

      # ── Fleet (ADR 0012) ─────────────────────────────────────────────────────────
      # All GENERATED by terraform/secrets (fleet.tf) — a fresh bring-up, nothing
      # operator-seeded. SAML SSO (no OIDC client secret). Path is under
      # authentik-managed/ only because that's the policy-globbed krg-prod namespace.
      # Split db.env (MySQL) / server.env (Fleet) so no image sees a var it doesn't own.
      {
        destination = "/run/krg/fleet/db.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/fleet" }}
          MYSQL_ROOT_PASSWORD={{ .Data.data.mysql_root_password }}
          MYSQL_PASSWORD={{ .Data.data.db_password }}
          {{- end }}
        '';
      }
      # FLEET_MYSQL_PASSWORD is the same value as MYSQL_PASSWORD (Fleet connects as the
      # `fleet` role); FLEET_SERVER_PRIVATE_KEY encrypts MDM assets (generate-once in
      # fleet.tf, never rotated). Consumed by both `fleet` and `fleet_migrate`.
      {
        destination = "/run/krg/fleet/server.env";
        perms = "0640";
        contents = ''
          {{- with secret "secret/data/krg-prod/authentik-managed/fleet" }}
          FLEET_MYSQL_PASSWORD={{ .Data.data.db_password }}
          FLEET_SERVER_PRIVATE_KEY={{ .Data.data.server_private_key }}
          {{- end }}
        '';
      }
    ];
  };

  # Provide the OEC installer archive path once the file is available locally.
  # krg.oecQualysTrellix.installerArchive = /path/to/oec-qualys-trellix.tar.gz;

  system.stateVersion = "25.11";
}
