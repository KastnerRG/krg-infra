# Setting up `deploy-ansible` on krg-deploy (OpenBao secret materialization)

This wires the **unattended** Ansible deploy path so
[`deploy/deploy-ansible.sh`](../deploy/deploy-ansible.sh) can pull NAS secrets
from OpenBao at apply time. After this, the push-to-main CD pipeline
(`.github/workflows/deploy.yml`) — and the nightly `ansible-apply` timer — can
run the synology playbook without an operator passing `-e @secrets`.

It's a **one-time operator setup on krg-deploy**. For the manual first deploy
of garage-ui itself, see [`garage-ui-bringup.md`](garage-ui-bringup.md) — that
one needs only steps 1–4 here (the AppRole), since it runs ansible by hand.

## How it works (what you're provisioning)

```
krg-deploy AppRole (role_id + secret_id files)
        │  bao write auth/approle/login
        ▼
   short-lived VAULT_TOKEN ──▶ bao kv get secret/e4e-nas/* ──▶ temp JSON -e @vars ──▶ ansible ──▶ shred
```

`deploy-ansible.sh` reads two files on the box:

| file (default path) | contents | secret? |
|---|---|---|
| `/var/lib/krg-admin/.secrets/openbao-role-id`   | AppRole `role_id`   | no (stable id) |
| `/var/lib/krg-admin/.secrets/openbao-secret-id` | AppRole `secret_id` | **yes** |

Override paths with `OPENBAO_ROLE_ID_FILE` / `OPENBAO_SECRET_ID_FILE`.

## Prerequisites

- **OpenBao (krg-vault)** initialized + unsealed; you have an **admin token**
  for the one-time mint below (`export VAULT_TOKEN=<admin>`).
- **`terraform/openbao` applied with the `secret/data/e4e-nas/*` read policy**
  (in this PR — `terraform/openbao/main.tf`). Without it the AppRole token can log in but `bao kv get
  secret/e4e-nas/...` returns 403. Confirm the merged `terraform/openbao`
  applied:
  ```bash
  bao policy read krg-deploy | grep -A2 'secret/data/e4e-nas'
  ```
- The NAS secrets are seeded in OpenBao — see *Seeding the NAS secrets* below.
- On krg-deploy: `bao`, `jq`, `ansible` on PATH (they are, via the host's
  `extraPackages`), and `VAULT_ADDR` reachable.

## Seeding the NAS secrets (#110)

`deploy-ansible.sh` materializes these from OpenBao at apply time. **Required**
(a missing one aborts the synology apply — never an empty password); **optional**
ones are omitted when absent. Seed the *current* values (migrate from the
operator's `secrets-syno.yml` / `secrets-hb.yml` — don't invent new ones, except
the OIDC secret which tofu writes):

| path | fields | req | source |
|---|---|---|---|
| `secret/e4e-nas/garage` | `rpc_secret`, `admin_token`, `metrics_token` | ✅ | existing live values (`secrets-garage.yml`) |
| `secret/e4e-nas/users` | `e4e-admin`, `e4e-automation` (passwords) | ✅ | `secrets-syno.yml` `synology_user_passwords.*`; `e4e-automation` = the tofu `dsm_password` |
| `secret/e4e-nas/snmp` | `auth_password`, `priv_password` | ✅ | `secrets-syno.yml` `snmp_v3_*` |
| `secret/e4e-nas/garage-ui-oidc` | `client_secret` | ⬜ | **tofu** (`terraform/authentik`) |
| `secret/e4e-nas/dsm-sso-oidc` | `client_secret` | ⬜ | **tofu** (`terraform/authentik`) — DSM web-login SSO (`synology_sso`) |
| `secret/e4e-nas/hyper-backup` | `<job>: <password>` | ⬜ | `secrets-hb.yml` (`{}` today — no jobs) |
| `secret/e4e-nas/ad` | `join_password` | ⬜ | one-time Domain-Admin pw for the AD join |

> Humans are AD-backed (winbind via `synology_ad`) — **no per-user secrets**.
> `secret/e4e-nas/users` holds only the break-glass `e4e-admin` + the
> `e4e-automation` API account.

```bash
bao kv put secret/e4e-nas/garage rpc_secret=… admin_token=… metrics_token=…
bao kv put secret/e4e-nas/users  e4e-admin=… e4e-automation=…
bao kv put secret/e4e-nas/snmp   auth_password=… priv_password=…
# optional, as applicable:
bao kv put secret/e4e-nas/ad     join_password=…
```

(`garage-ui-oidc` is written by `tofu apply` in `terraform/authentik`, not here.)

## 1. Get the role_id (non-secret)

From the OpenBao tofu workspace (on krg-deploy):

```bash
cd terraform/openbao
tofu output -raw krg_deploy_role_id
#   fallback with an admin token:
#   bao read -field=role_id auth/approle/role/krg-deploy/role-id
```

## 2. Mint a secret_id (secret)

`pull` (response-wrapped not needed for a local file). With an **admin token**,
or any token whose policy allows `create` on
`auth/approle/role/+/secret-id` (krg-deploy's own policy does, once it has a
token — but the *first* one is minted by admin):

```bash
bao write -f -field=secret_id auth/approle/role/krg-deploy/secret-id
```

> The role sets `token_ttl=1h`, `token_max_ttl=24h`; the secret_id itself has
> no TTL configured, so the file stays valid until you rotate it (step 6).

## 3. Place the files on krg-deploy

As `krg-admin` (the runner + ansible identity):

```bash
install -d -m 700 -o krg-admin -g krg-admin /var/lib/krg-admin/.secrets
umask 077
printf '%s' '<role_id from step 1>'   > /var/lib/krg-admin/.secrets/openbao-role-id
printf '%s' '<secret_id from step 2>' > /var/lib/krg-admin/.secrets/openbao-secret-id
chown krg-admin:krg-admin /var/lib/krg-admin/.secrets/openbao-role-id \
                          /var/lib/krg-admin/.secrets/openbao-secret-id
chmod 600 /var/lib/krg-admin/.secrets/openbao-{role,secret}-id
```

(`printf` not `echo` — avoids a trailing newline in the credential.)

## 4. Verify the AppRole can log in and read

As `krg-admin`:

```bash
export VAULT_ADDR=https://krg-vault.ucsd.edu:8200
tok="$(bao write -field=token auth/approle/login \
  role_id="$(< /var/lib/krg-admin/.secrets/openbao-role-id)" \
  secret_id="$(< /var/lib/krg-admin/.secrets/openbao-secret-id)")"
VAULT_TOKEN="$tok" bao kv get -field=admin_token secret/e4e-nas/garage >/dev/null \
  && echo "OK: AppRole login + e4e-nas read works" \
  || echo "FAIL: check policy (secret/data/e4e-nas/*) or that the secret is seeded"
unset tok
```

If this prints OK, `deploy-ansible.sh`'s materialization will work.

## 5. Go-live — provisioning the AppRole IS the switch

The synology stage is **already wired on** — `DEPLOY_SYNOLOGY=true` in both the
push-CD (`.github/workflows/deploy.yml`) and the 4:30 nightly
(`nix/hosts/krg-deploy/default.nix`). But it's **inert until you provision the
OpenBao AppRole creds** (steps 1–4): with no `role-id`/`secret-id` files the
synology stage **gracefully skips** (the rest of the fleet deploys normally). So
**provisioning the AppRole is the real go-live switch.**

> ⛔ **Provision the AppRole creds ONLY after the NAS bring-up reconciliation.**
> `DEPLOY_SYNOLOGY=true` with no `SYNOLOGY_TAGS` runs the **whole** playbook — its
> declarative sync **deletes** live config not in spec. That's the goal (drift
> reduction), but only safe once the spec captures intended live state
> (pre-flight captures + `.dss` backup + `--check --diff` first —
> `docs/e4e-nas-dsm.md`). The moment the AppRole creds + secrets exist, the next
> deploy/nightly converges the full NAS — so do the bring-up *first*.
>
> Secrets are not the blocker: the materialization covers all required groups
> (*Seeding* above) and **fails closed** if one is missing — never an empty
> password. For an interim garage-only converge ahead of the full bring-up, set
> `SYNOLOGY_TAGS=synology_certificate,synology_garage,synology_app_portal` (e.g.
> a manual `SYNOLOGY_TAGS=… ./deploy/deploy-ansible.sh` run on krg-deploy).

## 6. Rotate / revoke the secret_id

```bash
# rotate (mint a new one, replace the file, old logins keep their 1h token):
bao write -f -field=secret_id auth/approle/role/krg-deploy/secret-id \
  > /var/lib/krg-admin/.secrets/openbao-secret-id    # (admin or krg-deploy token)
# revoke all secret_ids for the role (forces re-provision):
bao write -f auth/approle/role/krg-deploy/secret-id-accessor/destroy   # per-accessor
```

## Troubleshooting

| symptom | cause |
|---|---|
| `FATAL: missing OpenBao AppRole file` | steps 1–3 not done, or wrong owner/perms |
| `FATAL: OpenBao AppRole login failed` | bad/rotated secret_id, or `VAULT_ADDR` unreachable from the runner |
| `cannot read secret/e4e-nas/garage` (403) | `terraform/openbao` not applied with this PR's `secret/data/e4e-nas/*` read policy, or secret not seeded |
| garage role asserts on a missing var | secret seeded but a field name mismatch — compare `bao kv get secret/e4e-nas/garage` keys to `deploy-ansible.sh`'s `jq` map |
