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

Four secrets reach the role as ansible extra_vars (NOT in spec, NOT in git),
all carried via the task's `environment:` directive — never argv, never
`ps`-visible. **OpenBao (`krg-vault`) is the source of truth**; the operator
file is only a local fallback for interactive runs.

| extra_var | OpenBao path (field) | who writes it | min len |
|---|---|---|---|
| `garage_rpc_secret`            | `secret/e4e-nas/garage` (`rpc_secret`)            | operator-seeded (pre-existing value)              | 32 |
| `garage_admin_token`           | `secret/e4e-nas/garage` (`admin_token`)           | operator-seeded (pre-existing value)              | 32 |
| `garage_metrics_token`         | `secret/e4e-nas/garage` (`metrics_token`)         | operator-seeded (pre-existing value)              | 32 |
| `garage_ui_oidc_client_secret` | `secret/e4e-nas/garage-ui-oidc` (`client_secret`) | **OpenTofu** (`terraform/authentik`, Authentik mints it) | 16 |

Why generate one but seed three: the OIDC client secret is **brand new**, so
OpenTofu creates it as part of registering the Authentik provider
([`terraform/authentik/applications_e4e.tf`](../../../../terraform/authentik/applications_e4e.tf)
+ [`vault_secrets.tf`](../../../../terraform/authentik/vault_secrets.tf)) —
writing it is pure creation, not a rotation. The three cluster tokens
**already exist** on the live NAS (baked into `garage.toml`); regenerating them
in tofu would force-rotate live secrets across multiple consumers (see
*Rotating secrets*), so they are **seeded into OpenBao once at their current
values** instead. The role fails fast if any is missing; render tasks are
`no_log: true` and the script payload omits secret values (only
`desired_sha256`).

### Getting the secrets to the role

- **On krg-deploy (unattended apply — the prod path):** krg-deploy's AppRole
  reads `secret/data/e4e-nas/*`
  ([`terraform/openbao/main.tf`](../../../../terraform/openbao/main.tf)); a
  wrapper materializes the extra_vars from OpenBao before the playbook runs,
  wired by [#85](https://github.com/KastnerRG/krg-infra/issues/85) (the
  synology-apply timer). Mirrors how krg-prod's vault-agent renders `.secrets/`
  — consumers keep reading their normal inputs; OpenBao populates them.
- **Local / interactive:** keep `~/.config/krg/secrets-garage.yml` (mode 0600,
  `-e @…`) as the fallback. Pull the tofu-generated OIDC secret into it with:
  ```bash
  bao kv get -field=client_secret secret/e4e-nas/garage-ui-oidc
  ```
  ```yaml
  # ~/.config/krg/secrets-garage.yml
  garage_rpc_secret: "<hex>"
  garage_admin_token: "<hex>"
  garage_metrics_token: "<hex>"
  garage_ui_oidc_client_secret: "<bao kv get … garage-ui-oidc>"
  ```

### One-time seed of the existing cluster tokens

The rpc/admin/metrics tokens predate OpenBao. Seed their **current** values
(from `secrets-garage.yml` / the live `garage.toml`) so krg-deploy can read
them — do NOT invent new values here (that forces a rotation; see *Rotating
secrets*):

```bash
bao kv put secret/e4e-nas/garage \
  rpc_secret="<current>" admin_token="<current>" metrics_token="<current>"
```

[#110](https://github.com/KastnerRG/krg-infra/issues/110) /
[#75](https://github.com/KastnerRG/krg-infra/issues/75) generalize this seeding
to the rest of the NAS secrets.

## First-time UI setup (one-shot)

The Authentik OIDC registration is **now IaC** (`terraform/authentik`). Only
the DSM AppPortal reverse-proxy + cert stay manual (DSM exposes no
provider/API for them — tracked alongside [#118](https://github.com/KastnerRG/krg-infra/issues/118)).

> **DNS note:** the dedicated `garage.e4e-nas.ucsd.edu` subdomain isn't
> registered (tracked in [#118](https://github.com/KastnerRG/krg-infra/issues/118)).
> Until then the UI is served under the NAS's own hostname on a dedicated
> port: **`https://e4e-nas.ucsd.edu:8443`**. When the subdomain lands, update
> `spec.ui.public_hostname` / `public_port` / `public_url` (and the redirect
> URI in `terraform/authentik/applications_e4e.tf`) and reissue the cert.

1. **Apply the Authentik OpenTofu.** From [`terraform/authentik/`](../../../../terraform/authentik/)
   (per that module's README — needs the Authentik admin token + a vault
   token):
   ```bash
   tofu apply   # or: tofu apply -target=authentik_provider_oauth2.garage_ui -target=authentik_application.garage_ui
   ```
   Creates the `garage-ui` OAuth2 provider + application + the `Garage Admins`
   group, and writes the generated client secret to
   `secret/e4e-nas/garage-ui-oidc`. **No hand-entry, no copy-paste:** the
   redirect URI (`…:8443/auth/oidc/callback`), slug (`garage-ui` → issuer
   `…/application/o/garage-ui/`), and `groups` scope are all fixed in the .tf
   to match `spec.ui.oidc`. Admins = members of the `Garage Admins` Authentik
   group (`spec.ui.oidc.admin_roles`).
2. **Seed the cluster tokens** into OpenBao if not already done (see *Secrets →
   One-time seed*).
3. **DSM reverse-proxy + Let's Encrypt cert (manual — no IaC).** Control Panel
   → Login Portal → Reverse Proxy → Create:
   - Description: `Garage UI`
   - Source: HTTPS, hostname `e4e-nas.ucsd.edu`, port `8443`; check "Enable HSTS", "HTTP/2"
   - Destination: HTTP, `127.0.0.1`, `8080`
   - Save, then Control Panel → Security → Certificate → ensure a
     Let's Encrypt cert for `e4e-nas.ucsd.edu` exists (DSM web likely already
     has one for itself on `:6021`) and assign it to the new reverse-proxy
     entry. No separate cert per port — same `e4e-nas.ucsd.edu` cert covers
     `:6021`, `:8443`, and any other AppPortal entry on this host.
   - DSM firewall: allow `:8443` from the same sources that reach DSM web.
4. **Run the role.** Materialize the secrets (krg-deploy: automatic, #85;
   local: pull the OIDC secret into `secrets-garage.yml` per *Secrets*), then
   apply. **Use the full `--tags=synology_garage`, not `--tags=garage_ui`
   alone, on first UI bring-up** — only the full run drags the garage
   `v1→v2.3.0` bump that garage-ui's `/v2/` admin API requires (the bump lives
   in the untagged `deploy` task; `garage_ui` alone would deploy the UI against
   a v1 API).

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

## Rotating secrets

There is no "tofu apply rotates it for you" — the value lives in OpenBao, but
each secret **fans out to consumers that an apply must re-render**, and two of
them reach *other* hosts. Rotate deliberately, in order:

| secret | consumers | rotation steps |
|---|---|---|
| `rpc_secret` | `garage.toml` only | `bao kv put secret/e4e-nas/garage rpc_secret=<new>` → re-run role (re-renders `garage.toml`, restarts garage). Single-node, so no peer coordination. |
| `admin_token` | `garage.toml` **+ garage-ui `config.yaml` + any S3/admin client/tooling** | `bao kv put … admin_token=<new>` → re-run **full** role (re-renders *both* `garage.toml` and the UI config, restarts both) → update any external admin client. |
| `metrics_token` | `garage.toml` **+ krg-prod Prometheus scrape config** | `bao kv put … metrics_token=<new>` → re-run role → **update the garage scrape job's bearer token on krg-prod and reload Prometheus** (cross-host — easy to forget; metrics silently 401 until you do). |
| `garage_ui_oidc_client_secret` | garage-ui `config.yaml` + the Authentik provider | rotate in Authentik: `tofu apply -replace=authentik_provider_oauth2.garage_ui` (regenerates the secret + rewrites `secret/e4e-nas/garage-ui-oidc`) → re-run the role (re-renders the UI config, restarts the UI). Single consumer. |

The JWT signing key (`/volume1/docker/garage-ui/jwt-key.pem`) is **not** one of
these — it's generated once on-box and persisted so UI sessions survive
restarts; deleting it (then re-running `render-ui-config`) regenerates it and
invalidates all live sessions (a logout-everyone, not a secret rotation).

## Out of scope

- **Buckets / access keys / policies / quotas** — TODO under
  [`spec/e4e-nas/garage.yml`](../../../../spec/e4e-nas/garage.yml) `buckets:` /
  `keys:`. Tracked in #101 sub-PR 5; will extend this role with `buckets` /
  `keys` subcommands (`garage bucket create`, `garage key new`,
  `garage bucket allow`).
- **DSM AppPortal reverse-proxy IaC + cert assignment** for the UI's public
  port — manual one-shot for now (steps in *First-time UI setup*); DSM exposes
  no provider/API for it.
- **Wildcard `*.s3.e4e.ucsd.edu` virtual-host-style bucket URLs** — the
  path-style `s3.e4e.ucsd.edu` endpoint is served now; per-bucket virtual
  hosts need a wildcard cert, tracked in [#118](https://github.com/KastnerRG/krg-infra/issues/118).
- **Unattended secret materialization on krg-deploy** — krg-deploy's AppRole
  can already read `secret/e4e-nas/*`; the wrapper that pulls them into
  extra_vars before the apply is [#85](https://github.com/KastnerRG/krg-infra/issues/85)
  (synology-apply timer). Estate-wide consumption migration: #110 / #75.
- **Migration to official `Deuxfleurs/garage-webadmin`** — #117.

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
