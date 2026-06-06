# synology_sso

Point **DSM's web login** (`e4e-nas.ucsd.edu:6021`) at **Authentik via OpenID
Connect**, and make SSO the **default** login — demoting the local password
form — from [`spec/e4e-nas/sso.yml`](../../../../spec/e4e-nas/sso.yml). Git is
truth; UI changes are drift ([ADR 0001](../../../../docs/adr/0001-iac-source-of-truth.md)).

This is the **DSM (client) half** of DSM SSO. The **IdP half** is OpenTofu:
[`terraform/authentik`](../../../../terraform/authentik/) registers the
`authentik_provider_oauth2.e4e_nas` client (id `e4e-nas`, app slug `e4e-nas`)
and writes its client secret to OpenBao `secret/e4e-nas/dsm-sso-oidc`
(`vault_secrets.tf`). Keep `client_id` / slug / issuer / redirect in lock-step
across the two layers.

## How it works

[`files/apply_sso.py`](files/apply_sso.py) (shipped via the `script` module;
DSM py3.8) — one subcommand, `oidc`, driving **two** DSM APIs (diffed + applied
independently, GET → diff → SET only on drift):

| API | method | what it does |
|---|---|---|
| `SYNO.Core.Directory.OIDC.SSO` | `set` (`profile="oidc"`) | the OIDC profile: `oidc_name`, `oidc_wellknown` (discovery URL — DSM derives the auth/token endpoints from it), `oidc_client_id`, `oidc_client_secret`, `oidc_redirect_uri`, `oidc_scope`, `oidc_user_claim`, `oidc_allow_local_user`. |
| `SYNO.Core.Directory.SSO` | `set` | `enable_sso` — the **master SSO-service switch**. Configuring the profile is NOT enough: DSM only renders the SSO login button once this is on. Applied *after* the profile. |
| `SYNO.Core.Directory.SSO.Setting` | `set` | `sso_default_login` — the "default to SSO instead of the password form" toggle. |

The set is **partial** (managed fields + `profile` only — matching the wizard,
which doesn't send the DSM-derived endpoint fields), not a full-object overlay.

The OIDC **client secret** is read from the `DSM_SSO_OIDC_CLIENT_SECRET` env var
(never argv — same rationale as `synology_garage`). DSM's OIDC GET **does** return
it in plaintext, so the role diffs it **silently** to catch a rotation, but its
value is never printed (drift shows `"<changed>"`); the task carries `no_log: true`
and the drift-export snapshot is mode `0600` (uncommitted).

## Discovery (done — API shape verified 2026-06-05)

The DSM SSO surface was unknown at scaffold time; it was pinned via the sanctioned
"discovery is the only exception" step ([CLAUDE.md](../../../../CLAUDE.md) / ADR
0001) — a read-only `SYNO.API.Info` sweep plus a Chrome DevTools capture of the
**Control Panel → Domain/LDAP → SSO Client** OIDC wizard's Save:

- The guessed `SYNO.Core.SSO.Client` does **not** exist (err 102). The real
  surface is the `SYNO.Core.Directory.SSO.*` family; the OIDC profile lives at
  `SYNO.Core.Directory.OIDC.SSO` and the default-login toggle at
  `SYNO.Core.Directory.SSO.Setting` (both version 1).
- Save fires a single partial `OIDC.SSO set` with `profile="oidc"` + the `oidc_*`
  fields (string values JSON-quoted, e.g. `oidc_name="Authentik"`); the
  default-login control is a separate `SSO.Setting set`.

**Before the first real apply** still run `--check --diff` (read-only GETs) and
then confirm a login round-trip — and reconcile the **redirect URI**: DSM lets the
admin set `oidc_redirect_uri` freely, so it must be byte-identical to a value in
`authentik_provider_oauth2.e4e_nas.allowed_redirect_uris` (Authentik's event log
shows the exact URI DSM sent on a mismatch). Keep the role OUT of the unattended
converge until that login is confirmed.

## Anti-lockout

`set_as_default: true` makes Authentik the default login, but **never removes the
local password form** (DSM keeps a fallback link), and the break-glass
`e4e-admin` is **key-only SSH** ([`synology_ssh`](../synology_ssh/)) which
bypasses the web login entirely. A broken IdP / OIDC misconfig therefore can't
lock the box out. Do not add a "hide local login" toggle without re-checking that
path.

## Why a standalone role (not in `synology_base`)

`synology_base` is the universal baseline every managed DSM host gets; OIDC SSO
to *this lab's* Authentik is e4e-nas-specific (like `synology_garage`), so it
lives in the play as its own tagged role. If a second DSM is ever managed against
the same IdP, promote it into the baseline composer then.

## Secrets

| extra_var | OpenBao path (field) | who writes it |
|---|---|---|
| `dsm_sso_oidc_client_secret` | `secret/e4e-nas/dsm-sso-oidc` (`client_secret`) | **OpenTofu** (`terraform/authentik`, Authentik mints it) |

Fail-soft: if SSO is enabled in spec but the secret is empty (not materialized /
not passed via `-e`), the role **skips with a warning** rather than failing the
DSM converge — the box keeps its current login. Wiring the secret into the
unattended krg-deploy materialization (`deploy/deploy-ansible.sh`) is a follow-up
(it lives in the #136 secret-materialization PR).

## Run

```bash
# Dry run (self-gating read-only GET even without --check support on the box):
ansible-playbook playbook.yml --tags=synology_sso --check --diff \
  -e dsm_sso_oidc_client_secret="$(bao kv get -field=client_secret secret/e4e-nas/dsm-sso-oidc)"

# Apply:
ansible-playbook playbook.yml --tags=synology_sso \
  -e dsm_sso_oidc_client_secret="$(bao kv get -field=client_secret secret/e4e-nas/dsm-sso-oidc)"
```

## Validation

Pytest suite under `files/test_apply_sso.py` covers the OK/WOULD-CHANGE/CHANGED/
FAIL contract, the full-object overlay (unmanaged DSM fields preserved), the
write-only secret (in the SET payload, never in drift/stdout), and the
enabled-but-no-secret fail-fast. The tests pin the **idempotency engine**, not the
as-yet-unverified field names, so they stay green after a discovery flip.
