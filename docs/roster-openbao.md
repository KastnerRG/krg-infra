# Roster: OpenBao cutover

This change runs Slack and GitHub inside the roster backend, using the existing
host OpenBao Agent for startup secrets. It requires the matching integrated
`E4E-Roster-V3` release, whose Compose file contains only `backend` and `db`.
Do not deploy this override against the historical three-backend release.

## 1. Reconnect to the existing OpenBao

From an allowed lab/VPN network, use your operator terminal:

```bash
ssh krg-admin@krg-vault.ucsd.edu
export VAULT_ADDR=https://krg-vault.ucsd.edu:8200
bao status
```

- `Initialized: true`, `Sealed: false`: proceed to authentication.
- `Initialized: true`, `Sealed: true`: run `bao operator unseal` interactively,
  once for each distinct share required by the reported threshold (normally 3
  of 5). Enter shares only at its hidden prompt, then check `bao status` again.
- `Initialized: false`: stop and check the host/storage and recovery records.
  This is an existing deployment; do not initialize a replacement datastore as
  a way to reconnect. Use [the recovery runbook](openbao-bringup.md).
- Unreachable or a TLS error: check network access, `systemctl status openbao`,
  and certificate/service logs. Keep certificate verification enabled.

Unsealing unlocks the server; it does not authenticate your shell. For an existing
operator token, use `bao login -no-print` and enter it at the hidden prompt.
Use a token with only the access required for the steps below. Do not send tokens,
shares, secret values, or full secret responses to chat or commit them.

No mounts, roles, or policies need changing for this roster cutover. The existing
`krg-prod` AppRole reads `secret/data/krg-prod/*`; the deploy AppRole already
manages `secret/krg-prod/authentik-managed/*`. The host Agent's credentials are
staged by the existing deploy flow. See [OpenBao bring-up](openbao-bringup.md)
for recovery of that bootstrap if necessary.

## 2. Preserve and adopt the existing generated secrets

Roster secrets move from `terraform/authentik` to `terraform/secrets` so they exist
before the NixOS Agent renders them. Existing values must be adopted, including
the DB, session, LDAP, and OIDC secrets. Changing KV does not change the live
PostgreSQL role or directory service-account password.

Pause concurrent deployment runs during this one-time adoption. On `krg-deploy`,
use a checkout of this revision and the existing encrypted state. Load the
**existing** state passphrase through a hidden prompt:

```bash
read -rsp 'Existing state passphrase: ' TOFU_STATE_PASSPHRASE
export TOFU_STATE_PASSPHRASE
```

For an existing installation, adopt all four values, then inspect the plan:

```bash
TOFU_TARGETS=secrets TOFU_PLAN_ONLY=1 \
TOFU_IMPORT='random_password.roster_db secret/krg-prod/authentik-managed/roster db_password
random_password.roster_session secret/krg-prod/authentik-managed/roster session_secret
random_password.roster_ldap secret/krg-prod/authentik-managed/roster-ldap bind_password
random_password.roster_oidc_client_secret secret/krg-prod/authentik-managed/roster-oidc client_secret' \
  ./deploy/deploy-tofu.sh
```

`TOFU_PLAN_ONLY` still performs requested state imports; it only skips the apply.
Run in a private operator terminal: import output/state can contain secrets.
All four imported `random_password` resources must keep their values, with no
replacement. The new KV writers may show creates because ownership is moving
between separate states. Confirm the existing client ID is `e4e-roster` and the
issuer is `https://auth.krg.ucsd.edu/application/o/e4e-roster/` (or the configured
`authentik_url`). Stop if anything would rotate a live value.

After reviewing that plan, explicitly approve the existing generate-once guard
for this value-preserving adoption and apply the same revision:

```bash
TOFU_TARGETS=secrets \
TOFU_SECRETS_APPROVE='Roster state adoption; all four live values imported and plan reviewed' \
  ./deploy/deploy-tofu.sh
```

Then plan/apply `TOFU_TARGETS=authentik` through the same script. The old ownership
is removed using `destroy = false`; live KV entries are retained, and Authentik
reads the preserved OIDC secret from the early workspace. Confirm no changes to
the effective roster client secret. Do not run an older Authentik revision after
this handoff.

For a genuinely fresh installation with none of these KV paths present, normal
`TOFU_TARGETS=secrets` generation suffices; do not use the adoption bypass. Retain
the encrypted state and its passphrase. Complete Authentik configuration before
expecting browser sign-in to work.

## 3. Seed the encryption key once

The operator-managed KV-v2 entry is `secret/krg-prod/roster-crypto`, field
`encryption_key`: exactly 64 hexadecimal characters. Back up the matching key
with recovery records for the roster database.

If integrations have already stored encrypted credentials, import their **existing
key** through protected stdin. Do not generate a replacement. For a fresh key
domain only, an authorized operator can run:

```bash
set -o pipefail
openssl rand -hex 32 | tr -d '\n' | \
  bao kv put -cas=0 -mount=secret krg-prod/roster-crypto encryption_key=-
```

CAS 0 refuses to overwrite an existing entry. Never delete an existing entry to
make this command succeed. Check that all required paths and fields exist without
printing values before activating the Agent additions.

## 4. Activate the matching roster and infrastructure revisions

1. Complete the application security prerequisites documented in the roster's
   `docs/deployment.md` before public use.
2. Back up PostgreSQL and its matching key. Preserve the current Compose project
   identity and database volume; a database rebuild is not required.
3. Prepare the matching roster revision in `/var/lib/krg/e4e-roster`. Build its
   backend image using the existing deployment procedure. A systemd restart does
   not build the image.
4. Keep nonsecret settings in the checkout `.env`: `ROSTER_HOST`,
   `ROSTER_BASE_URL`, `DB_HOST=db`, DB name/user/port, OIDC issuer/callback,
   LDAP URL/search DNs/domain, `SYSTEM_ADMIN_GROUP`, and initially
   `INTEGRATION_AUTO_SYNC=false`. Use the roster's minimal setup guide for the
   complete example. Remove the secret values from this file after preserving
   them in OpenBao.
5. Deploy this infra revision through the existing orchestrator. Compose must
   support `!override` and raw env files (2.30+). The Agent renders root-only
   `/run/krg/roster/backend.env` and `/run/krg/roster/compose.env` in a `0700`
   directory. The latter supplies host-side `DB_PASSWORD` interpolation; the
   former supplies backend runtime secrets. A missing path/field fails the
   **shared Agent**, potentially blocking other production stacks too.
6. Verify file modes and service state without displaying file contents:

   ```bash
   sudo systemctl status openbao-agent e4e-roster --no-pager
   sudo stat -c '%a %U:%G %n' /run/krg/roster /run/krg/roster/*.env
   ```

7. Recreate the backend through the same Compose project after an image or
   runtime-environment change. Verify SSO login and organization isolation.
   Configure each organization's Slack and GitHub connections in roster Settings;
   test linking and grants before enabling weekly discovery or scheduled grants.
   Retired sidecars are removed by the existing `--remove-orphans` behavior.

The application still receives `ENCRYPTION_KEY` in its environment. This removes
persistent checkout secrets but does not hide them from host/Docker administrators.
`ENCRYPTION_KEY_FILE` and OpenBao Transit are not implemented. Provider tokens and
GitHub private keys belong in the roster Settings UI, not these env files.

## Updates and recovery

The Agent is a one-shot renderer. Rerender after a secret change, then recreate
the affected container; `docker restart` does not reload environment files. Do not
add a reload hook that merely restarts the roster container for this purpose.

Restore a roster database together with its original encryption key. Coordinate
application/infra rollback: the old sidecar override and the new integrated
Compose file are incompatible, and an old secret-generating workspace must not
resume ownership. Follow [OpenBao recovery](openbao-bringup.md#backup--recovery)
for the secrets server; never reinitialize it just to recover access.

CLI reference: [status](https://openbao.org/docs/commands/status/),
[interactive unseal](https://openbao.org/docs/commands/operator/unseal/),
[login](https://openbao.org/docs/commands/login/).
