# synology_garage

Deploy + configure **Garage S3** on e4e-nas's Container Manager from
[`spec/e4e-nas/garage.yml`](../../../../spec/e4e-nas/garage.yml). Replaces the
prior `synology_container_project.garage` Terraform resource — see
[ADR 0007 "Garage retreat"](../../../../docs/adr/0007-dsm-config-ansible-not-terraform.md)
for why the surface moved from OpenTofu to Ansible (three distinct provider
bugs in one session: #110/#113/#114). Git is truth; on-NAS edits are drift
([ADR 0001](../../../../docs/adr/0001-iac-source-of-truth.md)).

## How it works

[`files/apply_garage.py`](files/apply_garage.py) (shipped via the `script`
module; DSM py3.8) — five subcommands, run in load-bearing order by
`tasks/main.yml`:

| subcommand | what it does | idempotency |
|---|---|---|
| `render-config`    | Atomic-write `/volume1/docker/garage/garage.toml` (root:root 0400) from spec.config + 3 secret env vars. | sha256 compare of full file content |
| `deploy`           | Render `docker-compose.yml` next to the toml; `docker compose up -d` when the compose file or container image drifts, or when the container isn't running. | Diff vs current compose file + `docker inspect` |
| `layout`           | Single-node `garage layout assign -z <zone> -c <cap> <NODE_ID>` + `garage layout apply --version 1`. | No-op if a layout (version ≥ 1) already exists — anti-rebalance guard |
| `render-ui-config` | Atomic-write `/volume1/docker/garage-ui/config.yaml` (root:root 0400) from spec.ui + GARAGE_ADMIN_TOKEN + GARAGE_UI_OIDC_CLIENT_SECRET env vars. Generates + persists `jwt-key.pem` (Ed25519) once so login sessions survive restarts. Skipped when `ui:` is absent from spec. | sha256 + `jwt-key.pem` existence |
| `deploy-ui`        | Render `garage-ui/docker-compose.yml`; `docker compose up -d`. Same drift logic as `deploy`. | Diff vs current compose file + `docker inspect` |

The role does **not** use DSM's `SYNO.Docker.Project` API. We invoke
`docker compose` directly (the underlying primitive). Containers still
appear in DSM Container Manager's "Container" tab, just not as grouped
"Projects". The trade is intentional: simpler, no upstream-bug surface.

The UI (Noooste/garage-ui) speaks OIDC natively and is the only Garage
admin UI today that does so without a forward-auth proxy outpost. Long-term
plan is to swap to the official `Deuxfleurs/garage-webadmin` once it leaves
"do not use yet" — tracked in [#117](https://github.com/KastnerRG/krg-infra/issues/117).

## Secrets

Four secrets are required at apply-time, supplied as ansible extra_vars
(NOT in spec, NOT in git). All carried via the task's `environment:`
directive — never argv, never `ps`-visible:

- `garage_rpc_secret`            — internal Garage RPC HMAC key (single-node still needs it set)
- `garage_admin_token`           — bearer token for the admin API on `:3903` (UI reuses this)
- `garage_metrics_token`         — bearer token for the Prometheus metrics endpoint
- `garage_ui_oidc_client_secret` — Authentik OIDC client secret for garage-ui (≥ 16 chars). Required only when spec has a `ui:` block.

The first three must be ≥ 32 chars; generate with `openssl rand -hex 32`. The
fourth comes from Authentik when you create the OAuth2 provider (see
*First-time UI setup* below). The role fails fast with a clear message if
any is missing. Render tasks carry `no_log: true` and the script's stdout
payload deliberately omits secret values (only `desired_sha256`).

Interim source: operator's `~/.config/krg/secrets-garage.yml` (mode 0600),
loaded via `-e @~/.config/krg/secrets-garage.yml`. The keys:

```yaml
garage_rpc_secret: "<hex>"
garage_admin_token: "<hex>"
garage_metrics_token: "<hex>"
garage_ui_oidc_client_secret: "<from Authentik provider create>"
```

Replaced by [#110 (OpenBao migration)](https://github.com/KastnerRG/krg-infra/issues/110) once that lands.

## First-time UI setup (one-shot, operator-driven)

The UI's OIDC flow + DSM AppPortal entry have no IaC home in this PR. Manual
steps before the first `--tags=garage_ui` apply succeeds:

> **DNS note:** the dedicated `garage.e4e-nas.ucsd.edu` subdomain isn't
> registered (tracked in [#118](https://github.com/KastnerRG/krg-infra/issues/118)).
> Until then the UI is served under the NAS's own hostname on a dedicated
> port: **`https://e4e-nas.ucsd.edu:8443`**. When the subdomain lands, update
> `spec.ui.public_hostname` / `public_port` / `public_url` and reissue the
> cert (the issue body has the full migration plan).

1. **Create the Authentik OAuth2 provider + application.** In Authentik's
   admin UI:
   - Providers → Create → OAuth2/OpenID Provider:
     - Name: `garage-ui`
     - Authorization flow: default `Authorize Application` (or your hardened equivalent)
     - Client type: Confidential; Client ID: `garage-ui` (matches `spec.ui.oidc.client_id`); copy the generated Client Secret to step 3 below
     - Redirect URIs: **`https://e4e-nas.ucsd.edu:8443/auth/oidc/callback`** (the UI auto-builds `{server.root_url}/auth/oidc/callback`)
     - Signing key + scopes: openid, email, profile, groups
   - Applications → Create:
     - Name: `Garage UI`; Slug: `garage-ui` (matches the issuer URL pattern `…/application/o/garage-ui/`)
     - Provider: the one you just created
     - Policy bindings: bind the `Garage Admins` group (or whichever Authentik group(s) `spec.ui.oidc.admin_roles` lists)
2. **Authentik issues the `groups` claim by default for OAuth2 providers.** If
   your install scopes it differently, set the matching path in
   `spec.ui.oidc.role_attribute_path`.
3. **Stash the client secret.** Append to `~/.config/krg/secrets-garage.yml`:
   `garage_ui_oidc_client_secret: "<the secret from step 1>"`.
4. **DSM reverse-proxy + Let's Encrypt cert.** Control Panel → Login Portal
   → Reverse Proxy → Create:
   - Description: `Garage UI`
   - Source: HTTPS, hostname `e4e-nas.ucsd.edu`, port `8443`; check "Enable HSTS", "HTTP/2"
   - Destination: HTTP, `127.0.0.1`, `8080`
   - Save, then Control Panel → Security → Certificate → ensure a
     Let's Encrypt cert for `e4e-nas.ucsd.edu` exists (DSM web likely already
     has one for itself on `:6021`) and assign it to the new reverse-proxy
     entry. No separate cert per port — same `e4e-nas.ucsd.edu` cert covers
     `:6021`, `:8443`, and any other AppPortal entry on this host.
   - DSM firewall: allow `:8443` from the same sources that reach DSM web.
5. **Run `--tags=garage_ui` to deploy.**

## Cluster bootstrap idempotency

After the first `apply` runs `garage layout assign` + `garage layout apply`,
the cluster layout has `version: 1`. Subsequent runs of the role observe
`version > 0` and exit no-change for the `layout` task — they do **not**
re-assign capacity.

This is deliberate. A capacity bump (e.g. `5T → 10T`) triggers a real
data-rebalance event on a live cluster, which is not something an unattended
`ansible-playbook playbook.yml` should kick off silently. To change layout,
edit `cluster.capacity` in the spec, then run the assign + apply manually
on the NAS:

```bash
# NB: the dxflrs/garage image has no `garage` on $PATH — the binary is at /garage.
# This is the same reason apply_garage.py's `layout` subcommand uses `/garage`.
ssh e4e-admin@e4e-nas.ucsd.edu \
  'sudo docker exec garage /garage layout assign -z dc1 -c 10T <NODE_ID> && \
   sudo docker exec garage /garage layout apply --version <N+1>'
```

(Where `<NODE_ID>` is the 16-hex-char short id from `/garage status` and
`<N+1>` is the next layout version.)

## Run

```bash
# Full apply (cluster + UI; operator-supplied secrets)
ansible-playbook playbook.yml --tags=synology_garage \
  -e @~/.config/krg/secrets-garage.yml

# UI-only apply (e.g. image bumps that don't touch the cluster)
ansible-playbook playbook.yml --tags=garage_ui \
  -e @~/.config/krg/secrets-garage.yml

# Dry run
ansible-playbook playbook.yml --tags=synology_garage --check --diff \
  -e @~/.config/krg/secrets-garage.yml
```

## Out of scope

- **Buckets / access keys / policies / quotas** — TODO under
  [`spec/e4e-nas/garage.yml`](../../../../spec/e4e-nas/garage.yml) `buckets:` /
  `keys:`. Tracked in #101 sub-PR 5; will extend this role with `buckets` /
  `keys` subcommands (`garage bucket create`, `garage key new`,
  `garage bucket allow`).
- **DSM AppPortal reverse-proxy IaC + cert assignment** for the UI's public
  port — manual one-shot for now (steps in *First-time UI setup*).
- **Wildcard `*.s3.e4e.ucsd.edu` virtual-host-style bucket URLs** — the
  path-style `s3.e4e.ucsd.edu` endpoint is served now; per-bucket virtual
  hosts need a wildcard cert, tracked in [#118](https://github.com/KastnerRG/krg-infra/issues/118).
- **Authentik provider/application IaC** — `terraform/authentik/` is owned
  by a parallel effort (per repo memory); manual setup until that lands.
- **Migration to official `Deuxfleurs/garage-webadmin`** — #117.
- **OpenBao-backed secrets** — #110.

## Validation

Pytest suite under `files/test_apply_garage.py` covers:

- TOML rendering (field substitution, secret injection via env vars, sha256 idempotency)
- compose YAML rendering with explicit `compose_path` (no implicit /volume mapping)
- deploy drift detection (image / compose-file / not-running)
- check-mode safety: missing `garage.toml` and absent container are reported as WOULD-CHANGE, not FAIL, so `--check --diff` works on a fresh box
- layout idempotency (version ≥ 1 → no-change without touching `garage layout assign`)
- secret `"`/`\n`/`\r` injection rejection (TOML + YAML defense)
- UI config render (OIDC + admin_token injection, JWT key persistence gating, env-var contract enforcement, secret redaction in payload)
- UI deploy drift detection

Run from the repo root: `pytest ansible/synology/roles/synology_garage/files/test_apply_garage.py`
