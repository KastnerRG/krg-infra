#!/usr/bin/env bash
# Init script: create the authentik non-superuser role and database.
# Runs once when the Postgres data directory is first initialised.
#
# AUTHENTIK_POSTGRESQL__PASSWORD is provided via env_file in compose.authentik.yml
# (.secrets/authentik_admin_password.env).  Postgres init scripts run under the
# postgres superuser with trust auth, so no password is needed for psql itself.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
	CREATE DATABASE authentik_db;
	CREATE ROLE authentik WITH
	    LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
	GRANT ALL PRIVILEGES ON DATABASE authentik_db TO authentik;
EOSQL

# Set the password. psql's `:'var'` interpolation proved unreliable under the
# postgres:18 client here — the token was sent literally (`syntax error at ":"`),
# leaving the role with NO password. Escape single quotes for the SQL string
# literal in the shell and inline it instead. ENCRYPTED makes the intent explicit.
authpw_esc=${AUTHENTIK_POSTGRESQL__PASSWORD//\'/\'\'}
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
    -c "ALTER ROLE authentik ENCRYPTED PASSWORD '${authpw_esc}'"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname="authentik_db" <<-EOSQL
	GRANT ALL ON SCHEMA public TO authentik;
EOSQL
