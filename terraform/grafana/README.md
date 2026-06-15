# terraform/grafana — Grafana objects

One target of the [`terraform/`](../README.md) OpenTofu layer. Manages
**Grafana's objects** declaratively with the `grafana/grafana` provider, instead
of click-ops in the Grafana UI.

> **Scope: config, not deployment.** Grafana runs as a Docker Compose stack on
> **krg-prod** (served at `monitoring.krg.ucsd.edu`). That stays. This target
> manages what lives *inside* Grafana.

## What's managed

- **Data source** — Prometheus at `http://prometheus:9090` (`datasources.tf`).
- **Dashboard** — `krg-waiter`, loaded from
  [`dashboards/krg-waiter.json`](dashboards/krg-waiter.json) (`dashboards.tf`).
- **SSO** — generic OAuth via Authentik (`sso.tf`), reading the OIDC client
  secret from OpenBao at `secret/krg-prod/grafana-oidc`. Role mapping (JMESPath
  on the userinfo `groups` claim): AD `Domain Admins` → `GrafanaAdmin`,
  everyone else → `Viewer`.

## Not managed (and why)

`folders.tf`, `teams.tf`, and `folder_permissions.tf` are intentionally empty —
team sync / per-lab folder RBAC needs **Grafana Enterprise**. Tracked in GitHub
issue #73.

## Prerequisites & state

- **Providers** (`providers.tf`): `grafana/grafana` (~> 3.0) + `hashicorp/vault`
  (~> 4.0). Grafana admin auth is `e4eadmin:<password>`, with the password read
  from OpenBao at `secret/krg-prod/grafana-admin` so it never appears in env.
- Export `TF_VAR_vault_addr` + `VAULT_TOKEN` before applying. Vars
  ([`variables.tf`](variables.tf)): `grafana_url`, `authentik_url`, `vault_addr`.
  The `grafana_url` / `authentik_url` defaults are the post-migration hosts
  (`monitoring.krg.ucsd.edu` / `auth.krg.ucsd.edu`); override per-apply if needed.
- **State is local for now** and holds secrets — the top-level
  `terraform/.gitignore` keeps `*.tfstate*` and `*.tfvars` out of git. See
  [state encryption](../README.md#secrets--state-shared-rules).

```bash
cd terraform/grafana
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<vault token>"
tofu init && tofu apply
```
