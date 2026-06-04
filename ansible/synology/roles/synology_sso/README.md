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
DSM py3.8) — one subcommand:

| subcommand | what it does | idempotency |
|---|---|---|
| `oidc` | `SYNO.Core.SSO.Client` set — enable OIDC, provider name, client id/secret, issuer, redirect, account-match attribute, default-login flag. FULL-OBJECT (partial = err 2001): GET → overlay managed keys → SET. | GET → diff → SET, only on drift |

The OIDC **client secret** is read from the `DSM_SSO_OIDC_CLIENT_SECRET` env var
(never argv — same rationale as `synology_garage`), and is **write-only**: DSM's
GET doesn't return it, so it's never diffed and never printed. The render task
carries `no_log: true`.

## ⚠️ Discovery required before first apply

The DSM **SSO-Client** API name (`SYNO.Core.SSO.Client`) and field keys in
`apply_sso.py` are a **best-guess** — there's no public DSM 7.3 API doc for this
applet, and it's newer than the surfaces the other `synology_*` roles wrap. This
is the sanctioned "discovery is the only exception" step
([CLAUDE.md](../../../../CLAUDE.md) / ADR 0001):

1. DSM web → **Control Panel → SSO Client** → open the OIDC profile wizard.
2. Capture the **Save** POST with Chrome DevTools (Network) — note the real
   `api=` name, `method`, `version`, and the exact field keys.
3. Flip `SSO_API` / `OIDC_FIELDS` in `apply_sso.py` (and the api/version in
   `tasks/export.yml`) to match.
4. `apply_sso.py oidc --check` against the NAS (read-only GET) to confirm the
   GET shape — **then** apply.

Also reconcile the DSM **redirect/callback** URI with
`authentik_provider_oauth2.e4e_nas.allowed_redirect_uris` once the wizard reveals
the exact path. Until all this is verified, treat the role as scaffolding —
**not** part of the unattended converge.

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
