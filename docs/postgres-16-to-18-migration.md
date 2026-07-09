# Postgres 16 → 18 major upgrade (krg-prod compose stacks)

The dependency-upgrade PR moves **three** of the krg-prod Postgres containers to the
**18.x** major — **authentik, mlflow, and outline** (outline was already on 18). The
other two krg-prod Postgres containers, `guacamole_postgres` (`compose.guacamole.yml`,
`postgres:16`) and `temporal-postgres` (`compose.temporal.yml`, `postgres:16.14`),
**stay on 16** and are out of scope here.

| Service | Stack file | Data volume | Old → new |
|---|---|---|---|
| `postgres_authentik` | `compose.authentik.yml` | `./authentik/postgres/data/` (bind) | 16.11 → 18.4 |
| `mlflow_postgres` | `compose.mlflow.yml` | `postgres_data` (named volume) | 16.11 → 18.4 |
| `outline_postgres` | `compose.outline.yml` | `outline_postgres_data` (named volume) | 18 → 18.4 (patch only — **no migration**) |

> **Why this is a manual step.** A Postgres data directory is **not**
> forward-compatible across majors. The official `postgres:18` image will **refuse
> to start** against a 16.x data dir (`database files are incompatible with
> server`). There is no auto-migration — bumping the tag alone produces a broken
> deploy. Authentik and MLflow therefore need a one-time dump/restore in a
> maintenance window **before** the new generation's compose stack starts.
> Outline is already on 18 (patch bump only — skip it here).

This follows the repo's IaC-strict posture: the spec (the compose tag) declares
the target major; the operator performs the documented data migration during the
deploy window, the same way DSM bring-up gates work (`docs/e4e-nas-dsm.md`).

## Procedure (per service: authentik, mlflow)

Run on **krg-prod**, in `/var/lib/krg/krg-prod/`, as the compose runtime user.
Do this **before** `nixos-rebuild switch` rolls out the new compose generation
(or stop the new stack immediately, run the migration, then `systemctl start`).

### 1. Take the stack down cleanly while still on 16.x

Pin the old image for the dump so the server matches the on-disk data:

```bash
cd /var/lib/krg/krg-prod
# Bring up ONLY the DB on the OLD major to dump it (compose still pinned to 16.11
# on the current generation — do this before switching).
docker compose -f <store-path>/compose.yml up -d postgres_authentik   # or mlflow_postgres
```

### 2. Dump the cluster

```bash
# Authentik (db owner role = authentik; dump the whole cluster to be safe):
docker exec postgres_authentik pg_dumpall -U postgres > authentik-pg16.sql

# MLflow:
docker exec <mlflow_postgres_container> pg_dumpall -U "${POSTGRES_USER:-mlflow}" > mlflow-pg16.sql
```

Verify the dump is non-empty and ends with `-- PostgreSQL database dump complete`.

### 3. Move the old data dir aside (do NOT delete until verified)

```bash
# Authentik (bind mount):
mv ./authentik/postgres/data ./authentik/postgres/data.pg16.bak
mkdir -p ./authentik/postgres/data

# MLflow (named volume): rename it so 18 initializes a fresh one.
docker volume rename krg-prod_postgres_data krg-prod_postgres_data_pg16_bak   # adjust project prefix
```

### 4. Switch to 18 and let it initialize an empty cluster

`nixos-rebuild switch` (new generation pins 18.4), or restart just the DB. The
init scripts / `POSTGRES_*` env create the empty cluster + roles on first boot.

### 5. Restore

```bash
docker exec -i postgres_authentik psql -U postgres < authentik-pg16.sql
docker exec -i <mlflow_postgres_container> psql -U "${POSTGRES_USER:-mlflow}" < mlflow-pg16.sql
```

### 6. Validate, then bring the app up

- Authentik: `authentik_server` healthy, login works, no migration errors in logs.
- MLflow: UI loads, experiments/runs present.

### 7. Clean up only after confirming

```bash
rm -rf ./authentik/postgres/data.pg16.bak
docker volume rm krg-prod_postgres_data_pg16_bak
rm authentik-pg16.sql mlflow-pg16.sql
```

## Rollback

The migration is non-destructive until step 7. To roll back: stop the stack,
restore the old image tag (`git revert` the compose bump), move the `.pg16.bak`
data dir / volume back, and start. Because the old data was only *renamed*, the
16.x cluster is intact.
