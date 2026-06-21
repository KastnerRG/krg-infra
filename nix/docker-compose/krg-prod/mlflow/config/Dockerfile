# MLflow tracking server with OIDC authentication via the mlflow-oidc-auth plugin
# (Authentik SSO). Access/admin are gated on the `groups` claim — see the OIDC_* env
# in ../../compose.mlflow.yml.
#
# Secrets are rendered to /run by krg.vaultAgent and injected via compose `env_file:`
# (OIDC_CLIENT_SECRET, SECRET_KEY, and the password-bearing MLFLOW_BACKEND_STORE_URI /
# OIDC_USERS_DB_URI). Nothing secret is baked into this image.

FROM python:3.12-slim

# Pinned for reproducibility. mlflow-oidc-auth 7.x requires mlflow>=3.10,<4 and
# Python>=3.10. Bump all three together (the plugin tracks the mlflow major).
ARG MLFLOW_VERSION=3.14.0
ARG MLFLOW_OIDC_AUTH_VERSION=7.3.1

RUN pip install --no-cache-dir \
    mlflow==${MLFLOW_VERSION} \
    psycopg2-binary \
    mlflow-oidc-auth==${MLFLOW_OIDC_AUTH_VERSION}

EXPOSE 5000

# Shell form (not exec) on purpose: --backend-store-uri / --artifacts-destination are
# CLI-only — MLflow does NOT read MLFLOW_BACKEND_STORE_URI / MLFLOW_ARTIFACTS_DESTINATION
# from the environment (only MLFLOW_SERVER_ALLOWED_HOSTS / _CORS_ALLOWED_ORIGINS are
# env-backed). So expand the two URIs (rendered with the DB password by vault-agent)
# into flags here. `--app-name oidc-auth` enables the OIDC plugin.
ENTRYPOINT ["sh", "-c", "exec mlflow server \
    --host 0.0.0.0 \
    --port 5000 \
    --app-name oidc-auth \
    --backend-store-uri \"$MLFLOW_BACKEND_STORE_URI\" \
    --artifacts-destination \"$MLFLOW_ARTIFACTS_DESTINATION\" \
    --serve-artifacts"]
