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
module; DSM py3.8) — three subcommands, run in load-bearing order by
`tasks/main.yml`:

| subcommand | what it does | idempotency |
|---|---|---|
| `render-config` | Atomic-write `/volume1/docker/garage/garage.toml` (root:root 0400) from spec.config + 3 secret extra_vars. | sha256 compare of full file content |
| `deploy`        | Render `docker-compose.yml` next to the toml; `docker compose up -d` when the compose file or container image drifts, or when the container isn't running. | Diff vs current compose file + `docker inspect` |
| `layout`        | Single-node `garage layout assign -z <zone> -c <cap> <NODE_ID>` + `garage layout apply --version 1`. | No-op if a layout (version ≥ 1) already exists — anti-rebalance guard |

The role does **not** use DSM's `SYNO.Docker.Project` API. We invoke
`docker compose` directly (the underlying primitive). Container still
appears in DSM Container Manager's "Container" tab, just not as a grouped
"Project". The trade is intentional: simpler, no upstream-bug surface.

## Secrets

Three secrets are required at apply-time, supplied as ansible extra_vars
(NOT in spec, NOT in git):

- `garage_rpc_secret`     — internal Garage RPC HMAC key (single-node still needs it set)
- `garage_admin_token`    — bearer token for the admin API on `:3903`
- `garage_metrics_token`  — bearer token for the Prometheus metrics endpoint

Each must be ≥ 32 chars; generate with `openssl rand -hex 32`. The role
fails fast with a clear message if any is missing. The `render-config`
task carries `no_log: true` and the script's output payload deliberately
omits the secret values (only `desired_sha256` to confirm a meaningful
change).

Interim source: operator's `~/.config/krg/secrets-garage.yml` (mode 0600),
loaded via `-e @~/.config/krg/secrets-garage.yml`. The keys:

```yaml
garage_rpc_secret: "<hex>"
garage_admin_token: "<hex>"
garage_metrics_token: "<hex>"
```

Replaced by [#110 (OpenBao migration)](https://github.com/KastnerRG/krg-infra/issues/110) once that lands.

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
# Apply (operator-supplied secrets)
ansible-playbook playbook.yml -e @~/.config/krg/secrets-garage.yml

# Dry run
ansible-playbook playbook.yml -e @~/.config/krg/secrets-garage.yml --check --diff
```

## Out of scope

- **Buckets / access keys / policies / quotas** — TODO under
  [`spec/e4e-nas/garage.yml`](../../../../spec/e4e-nas/garage.yml) `buckets:` /
  `keys:`. Tracked in #101 sub-PR 5; will extend this role with `buckets` /
  `keys` subcommands (`garage bucket create`, `garage key new`,
  `garage bucket allow`).
- **Wildcard DSM AppPortal reverse proxy + Let's Encrypt** for virtual-host-style
  per-bucket hostnames `*.s3.e4e.ucsd.edu` — #101 sub-PR 4 (separate role; needs a
  wildcard cert). The path-style endpoint `s3.e4e.ucsd.edu` is exposed in #116.
- **OpenBao-backed secrets** — #110.

## Validation

Pytest suite under `files/test_apply_garage.py` covers:

- TOML rendering (field substitution, secret injection, sha256 idempotency)
- compose YAML rendering with explicit `compose_path` (no implicit /volume mapping)
- deploy drift detection (image / compose-file / not-running)
- check-mode safety: missing `garage.toml` and absent container are reported as WOULD-CHANGE, not FAIL, so `--check --diff` works on a fresh box
- layout idempotency (version ≥ 1 → no-change without touching `garage layout assign`)
- secret double-quote rejection (TOML injection defense)

Run from the repo root: `pytest ansible/synology/roles/synology_garage/files/test_apply_garage.py`
