# terraform/secrets — early secret generation

This workspace **generates** the secrets that krg-prod services need at startup and
writes them to OpenBao under `secret/krg-prod/authentik-managed/*`. It depends only on
OpenBao, so it runs **early** in the deploy — before NixOS members (P2) whose
fail-closed `krg.vaultAgent` renders them.

## Why (the deploy-DAG fix)

The fleet deploy runs NixOS members (P2) **before** OpenTofu (P3). Historically
`terraform/authentik` (P3) both *configured* Authentik and *generated* the OIDC
`client_secret`s + DB passwords those services consume — so P2's fail-closed agent
read secrets that didn't exist yet → the stack failed closed (the #320 outage; the
openbao-migration manual ordering). Root cause: the `client_secret` was the only
secret we let Authentik mint, trapping generation behind "Authentik is up."

Fix: generate **everything** here (DB passwords + self-set `client_secret`s) early.
`authentik_provider_oauth2.client_id` is `Required` (we already set it) and
`client_secret` is settable, so we mint both and Authentik just *reads* the
`client_secret` back to set on its provider. The DAG becomes topological:

```
krg-vault (P0) → terraform/openbao (privileged) → terraform/secrets → NixOS members → terraform/authentik+grafana
```

No fail-open / optional secrets — the invariant stays "declared state or visible
failure"; we just guarantee the secret exists before the consumer runs.

## Which secrets live here

Only the secrets a **fail-closed P2 consumer** (the krg-prod `krg.vaultAgent`) renders
need to be generated early — those are the ones that can fail-close the stack. Today:
**temporal** (db + oidc), **guacamole** (db; its OIDC is implicit-flow, no secret),
**vaultwarden** (oidc), **mlflow** (db + secret_key + oidc), **outline** (db +
secret_key + utils_secret + oidc). The rest (`grafana-oidc`, roster, `guacamole-oidc`,
the e4e-nas pair, `proxmox-ldap-bind`) are consumed at tofu-time or by graceful
ansible — they can't fail-close the stack, so they stay in `terraform/authentik`.
**Rule:** when a secret becomes a vault-agent (P2) consumer, move it here.

## The generate-once invariant (and the deploy guard)

Every secret here is **generate-once**: a DB password (set into the database at
data-dir init) or an encryption key (encrypts data/sessions/MDM assets at rest). Once a
service has been deployed, its OpenBao secret is **live** and the consuming
database/app is pinned to it. Recreating it is catastrophic — a rotated DB password
locks the service out; a rotated encryption key (`secret_key`, `utils_secret`,
`server_private_key`) makes existing data undecryptable.

The trap: `random_password`/`random_id` emit a **fresh** value whenever they are absent
from the state the apply runs against. So an apply against state that has lost these
resources (or never had them — created out-of-band) **silently regenerates them and
overwrites the live OpenBao value**. This happened to outline + fleet: a deploy
regenerated all of their db/key secrets, locking Outline out of Postgres and corrupting
its encrypted columns, and locking Fleet out of MySQL. (Beware the seductive per-file
comment "brand-new bring-up, all pure CREATEs, no import needed" — it is only true
until the *first* deploy; after that the secret is live and must be imported.)

Two guardrails enforce the invariant:

1. **`deploy-tofu.sh` refuses to create-over-an-existing secret.** Before applying the
   `secrets` target it plans, and if the plan would **create** a `vault_kv_secret_v2`
   whose OpenBao path **already exists**, it aborts (exit 5): *why create a secret that
   already exists out there?* A genuinely new service is unaffected — its KV path
   doesn't exist yet, so it creates cleanly and comes up automatically. Bypass only with
   `TOFU_REPLACE` (deliberate rotation) or `TOFU_SECRETS_APPROVE=<reason>`.

2. **Adopt, don't recreate.** When the guard fires, import the live value — never
   recreate. `random_password` imports verbatim; **`random_id`** (`secret_key` /
   `utils_secret`) imports through the same `TOFU_IMPORT` — deploy-tofu.sh converts the
   KV `.hex` field to the base64url import ID automatically (a raw-hex import would land
   different bytes and silently rotate on the next apply).

   ```bash
   # Adopt outline's three live values without rotating them (random_id auto-converts):
   TOFU_TARGETS=secrets TOFU_STATE_PASSPHRASE='<passphrase>' TOFU_PLAN_ONLY=1 \
     TOFU_IMPORT="random_password.outline_db     secret/krg-prod/authentik-managed/outline db_password
   random_id.outline_secret_key   secret/krg-prod/authentik-managed/outline secret_key
   random_id.outline_utils_secret secret/krg-prod/authentik-managed/outline utils_secret" \
     ./deploy/deploy-tofu.sh        # confirm "No changes", then drop TOFU_PLAN_ONLY to apply
   ```

## Migration (one-time, per secret)

Two modes:

- **DB passwords — PRESERVE** (postgres set them at init; rotating locks out the live
  DB). Import only the **`random_password`** (the value to preserve) — the
  `vault_kv_secret_v2` is just re-asserted with the same value on apply (a no-op new
  version; importing it would need `sys/` mount introspection the AppRole lacks). Run
  the import through `deploy-tofu.sh`'s `TOFU_IMPORT` mode so the real encrypted state
  is wired and the value is read from OpenBao (never your shell). Format per line:
  `ADDR KVPATH FIELD`.
  ```bash
  # On krg-deploy. PLAN_ONLY first to confirm each import preserved the value.
  # One ADDR/KVPATH/FIELD line per DB password (temporal already migrated):
  TOFU_TARGETS=secrets TOFU_STATE_PASSPHRASE='<passphrase>' TOFU_PLAN_ONLY=1 \
    TOFU_IMPORT="random_password.guacamole_db secret/krg-prod/authentik-managed/guacamole db_password" \
    ./deploy/deploy-tofu.sh
  # CONFIRM: random_password.guacamole_db => No changes (value preserved)
  ```
- **OIDC `client_secret`s — ROTATE** (no import). The first apply mints a fresh value
  and writes it; `terraform/authentik` sets the same value on the provider in the same
  run, and the consumer re-renders — so Authentik + consumer converge within the run.

### Apply order (one-time)
1. `terraform/secrets`: run the `TOFU_IMPORT` PLAN_ONLY above and **confirm
   `random_password.temporal_db` shows NO change** (preserved); the two
   `vault_kv_secret_v2` + the OIDC `random_password` show as creates (KV re-assert is a
   same-value no-op; the OIDC secret is the intended rotation). Then **apply** — same
   command, keep `TOFU_IMPORT` (idempotent), drop `TOFU_PLAN_ONLY`.
2. `terraform/authentik`: `TOFU_TARGETS=authentik ./deploy/deploy-tofu.sh` — applies the
   `removed {}` drops (no destroy) + sets `client_secret` from the data source (a no-op
   when it already matches; the rotation lands because step 1 wrote the fresh value).
3. `DEPLOY_NIXOS_HOSTS=krg-prod ./deploy/deploy-nixos.sh`: vault-agent re-renders
   temporal's env from the rotated client_secret.

Steady state (and every future fresh deploy) needs none of this — `terraform/secrets`
runs early and the secrets simply pre-exist.

## Gate — is `client_secret` diff-stable?

The whole OIDC half rests on `authentik_provider_oauth2.client_secret` being settable
without a perpetual diff or a forced replace. Validated here on temporal first. If it
turns out unstable, only the OIDC relocation needs rework — the DB-password relocation
(the other fail-closed P2 consumer) still stands.
