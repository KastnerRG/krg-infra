-- mlflow-oidc-auth keeps its users/permissions in a SEPARATE database from MLflow's
-- experiment backend store (OIDC_USERS_DB_URI -> .../mlflow_auth vs the backend
-- .../mlflow). The postgres image only auto-creates POSTGRES_DB (mlflow), so create
-- the auth DB here. Runs once, owned by the same POSTGRES_USER (mlflow), only on a
-- fresh data dir (/docker-entrypoint-initdb.d) — a no-op on an already-initialized
-- volume.
CREATE DATABASE mlflow_auth;
