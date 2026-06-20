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

> **Pilot:** this PR moves only **temporal** (it has both a DB password and a
> `client_secret`) to validate the pattern + the diff-stability gate below. The
> remaining apps follow in the sweep PR once the gate is confirmed.

## Migration (one-time, per secret)

Two modes:

- **DB passwords — PRESERVE** (postgres set them at init; rotating locks out the live
  DB). Import the existing value so the first apply is a no-op:
  ```bash
  # On krg-deploy, krg-deploy AppRole VAULT_TOKEN exported, in terraform/secrets:
  tofu import random_password.temporal_db "$(bao kv get -field=db_password secret/krg-prod/authentik-managed/temporal)"
  tofu import vault_kv_secret_v2.temporal   secret/krg-prod/authentik-managed/temporal
  ```
- **OIDC `client_secret`s — ROTATE** (no import). The first apply mints a fresh value
  and writes it; `terraform/authentik` sets the same value on the provider in the same
  run, and the consumer re-renders — so Authentik + consumer converge within the run.

### Apply order (one-time)
1. `terraform/secrets`: run the imports above, then **`tofu plan` and confirm the
   `temporal` db_password shows NO change** (import worked) before apply. Apply.
2. `terraform/authentik`: applies the `removed {}` drops (no destroy) + sets
   `client_secret` from the data source. **Gate:** `tofu plan` must show the temporal
   provider's `client_secret` *updating in place* — **not** a resource replace and
   **not** a perpetual diff. If it wants to replace/clobber, stop (see Gate below).
3. `nixos-rebuild krg-prod`: vault-agent re-renders temporal's env from the rotated
   client_secret.

Steady state (and every future fresh deploy) needs none of this — `terraform/secrets`
runs early and the secrets simply pre-exist.

## Gate — is `client_secret` diff-stable?

The whole OIDC half rests on `authentik_provider_oauth2.client_secret` being settable
without a perpetual diff or a forced replace. Validated here on temporal first. If it
turns out unstable, only the OIDC relocation needs rework — the DB-password relocation
(the other fail-closed P2 consumer) still stands.
