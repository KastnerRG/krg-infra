# App-secret delivery for the reference-manager interior. Mirrors fishsense-services
# deploy/incus/secrets.nix: nixosModules.tenant's vault-agent renders only the CERT
# (reference-manager.vm); app secrets are renders we add here (the list merges with the
# platform's). ONE FILE PER CONSUMER, so no container holds a credential it doesn't use.
#
# ── OpenBao layout the tenant-reference-manager AppRole reads ──────────────────────────
# PLATFORM writes (krg-infra tofu — nothing to seed by hand):
#   tenants/reference-manager/generated/app  { db_password, session_secret }
#                    # generate-once (terraform/secrets/reference_manager.tf)
#   tenants/reference-manager/oidc/web       { client_id, client_secret, issuer_url }
#                    # the API's Authentik client (terraform/authentik/reference_manager.tf)
#   e4e-nas/garage-keys/reference-manager    { access_key_id, secret_access_key }
#                    # the Garage key, minted + imported by the e4e-nas deploy
#                    # (deploy/deploy-ansible.sh). Read IN PLACE — its source of truth
#                    # is there; the AppRole has an explicit read grant on this one path
#                    # (terraform/openbao var.tenants extra_read_paths).
#
# ⚠️ vault-agent is FAIL-CLOSED (errorOnMissingKey): a referenced path/field that
# doesn't exist takes the whole stack down — including the reference-manager.vm cert,
# so the inner Traefik too. All three paths exist once krg-infra's onboarding PRs are
# applied; check them (keys only) before the first converge (HANDOFF §4).
#
# Rotating one: rotate at the source, `systemctl restart openbao-agent.service`, then
# `systemctl restart reference-manager.service` (env_file is read at container
# create). NEVER rotate generated/app.db_password on a live slot: the role's password
# is in the database (HANDOFF §7). Never `cat` a render.
#
# Paths are spelled out in full so `grep garage-keys` finds every consumer.
{
  krg.vaultAgent.renders = [
    {
      # The postgres container. Applied by the image only when initialising an empty
      # volume (first boot); afterwards the role's password lives in the database.
      destination = "/run/tenant/secrets/postgres.env";
      contents = ''
        {{ with secret "secret/data/tenants/reference-manager/generated/app" }}POSTGRES_PASSWORD={{ .Data.data.db_password }}{{ end }}
      '';
    }
    {
      # The API: its database, session signing key, Garage key, and Authentik client.
      destination = "/run/tenant/secrets/api.env";
      contents = ''
        {{ with secret "secret/data/tenants/reference-manager/generated/app" }}REFMAN_DATABASE_URL=postgresql+asyncpg://refman:{{ .Data.data.db_password | urlquery }}@postgres:5432/refman
        REFMAN_SESSION_SECRET={{ .Data.data.session_secret }}{{ end }}
        {{ with secret "secret/data/e4e-nas/garage-keys/reference-manager" }}REFMAN_S3_ACCESS_KEY={{ .Data.data.access_key_id }}
        REFMAN_S3_SECRET_KEY={{ .Data.data.secret_access_key }}{{ end }}
        {{ with secret "secret/data/tenants/reference-manager/oidc/web" }}REFMAN_OIDC_ISSUER={{ .Data.data.issuer_url }}
        REFMAN_OIDC_CLIENT_ID={{ .Data.data.client_id }}
        REFMAN_OIDC_CLIENT_SECRET={{ .Data.data.client_secret }}{{ end }}
      '';
    }
    {
      # The nightly dump: the refman role's password only.
      destination = "/run/tenant/secrets/pg-dump.env";
      contents = ''
        {{ with secret "secret/data/tenants/reference-manager/generated/app" }}PGPASSWORD={{ .Data.data.db_password }}{{ end }}
      '';
    }
    {
      # The dump mirror: the Garage key only (rclone's env-configured `garage` remote).
      destination = "/run/tenant/secrets/pg-backup-sync.env";
      contents = ''
        {{ with secret "secret/data/e4e-nas/garage-keys/reference-manager" }}RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID={{ .Data.data.access_key_id }}
        RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY={{ .Data.data.secret_access_key }}{{ end }}
      '';
    }
  ];
}
