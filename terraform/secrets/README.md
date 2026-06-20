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
  DB). Import only the **`random_password`** (the value to preserve). Do **not** import
  the `vault_kv_secret_v2` — its import introspects the mount via `sys/`, which the
  krg-deploy AppRole policy doesn't grant ("no mount found"); the KV entry is simply
  re-asserted with the same value on apply (a no-op new version). `random_password`
  import is the local `random` provider — no Vault, works with the AppRole:
  ```bash
  # On krg-deploy, in terraform/secrets:
  tofu import random_password.temporal_db "$(bao kv get -field=db_password secret/krg-prod/authentik-managed/temporal)"
  tofu plan   # CONFIRM random_password.temporal_db => No changes (value preserved)
  ```
- **OIDC `client_secret`s — ROTATE** (no import). The first apply mints a fresh value
  and writes it; `terraform/authentik` sets the same value on the provider in the same
  run, and the consumer re-renders — so Authentik + consumer converge within the run.

### Apply order (one-time)
1. `terraform/secrets`: run the `random_password` import above, then **`tofu plan` and
   confirm `random_password.temporal_db` shows NO change** (preserved) before apply.
   The two `vault_kv_secret_v2` + the OIDC `random_password` show as creates (the KV
   re-assert is a same-value no-op; the OIDC secret is the intended rotation). Apply.
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
