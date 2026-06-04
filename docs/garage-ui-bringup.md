# Garage UI bring-up runbook (krg-deploy)

One-time, operator-driven first deploy of the Garage admin UI
(Noooste/garage-ui) on **e4e-nas**, run from the **krg-deploy** control node.
After this, the same secret flow runs under CD (`deploy/deploy-ansible.sh`
materializes the same vars from OpenBao); this runbook is the manual,
**targeted** first deploy that doesn't wait on the full NAS bring-up.

See also: [`ansible/synology/roles/synology_garage/README.md`](../ansible/synology/roles/synology_garage/README.md)
(role internals + rotation), ADR 0005 (krg-deploy is the control node).

## Prerequisites

- **#115 + #116 merged to main** (garage cluster role + garage-ui + the
  `terraform/authentik` garage-ui resources). The `terraform/openbao`
  `secret/data/e4e-nas/*` read policy ships in **this PR**
  (`terraform/openbao/main.tf`).
- **OpenBao (krg-vault)** initialized + unsealed, KV-v2 mounted at `secret/`.
- On **krg-deploy**: `tofu`, `bao`, `ansible`, `jq` on PATH (they are, via the
  host's `extraPackages`); `VAULT_ADDR=https://krg-vault.ucsd.edu:8200`; SSH +
  NOPASSWD sudo to `e4e-admin@e4e-nas.ucsd.edu`.
- A vault token with admin rights for the tofu applies + the one-time seed
  (steps 1–3); the AppRole creds for the apply (step 5).

> All commands run **on krg-deploy** unless noted. Secrets never go on argv or
> into logs; the materialized vars file is mode-0600 and shredded on exit.

## 1. Apply the OpenBao layer (AppRole policies incl. e4e-nas read)

```bash
cd terraform/openbao
# terraform/openbao/.deploy-env exports VAULT_TOKEN (admin) + TF_VAR_*
tofu init && tofu apply
```

This creates/updates the `krg-deploy` AppRole policy that grants
`read` on `secret/data/e4e-nas/*` (added in this PR).

## 2. Apply the Authentik layer (garage-ui provider + OIDC secret writeback)

> ⚠️ `terraform/authentik` is the SSO effort's module (#79/#81) — `tofu apply`
> reconciles **all** Authentik objects. Coordinate, or `-target` just ours.

```bash
cd terraform/authentik
# .deploy-env exports TF_VAR_authentik_token, VAULT_TOKEN, TF_VAR_ldap_bind_password
tofu init && tofu apply
#   targeted alternative:
#   tofu apply \
#     -target=authentik_provider_oauth2.garage_ui \
#     -target=authentik_application.garage_ui \
#     -target=authentik_group.garage_admins \
#     -target=vault_kv_secret_v2.garage_ui_oidc
```

Verify the OIDC secret landed in OpenBao:

```bash
bao kv get secret/e4e-nas/garage-ui-oidc      # → client_id / client_secret / issuer_url
```

Also confirm the `Garage Admins` Authentik group has the intended members
(AD-synced or manual) — membership is what grants UI admin.

## 3. Seed the existing cluster tokens into OpenBao (one-time, NO rotation)

`rpc/admin/metrics` predate OpenBao and are live in `garage.toml`. Seed their
**current** values — do not invent new ones (that forces a multi-consumer
rotation; see the role README "Rotating secrets"):

```bash
bao kv put secret/e4e-nas/garage \
  rpc_secret="<current>" admin_token="<current>" metrics_token="<current>"
bao kv get secret/e4e-nas/garage              # verify
```

## 4. DSM AppPortal reverse-proxy + cert (declarative — applied in step 5)

These are **no longer manual** — they're in the spec and applied by the roles
in step 5:

- **Reverse proxies** (`spec/e4e-nas/app-portal.yml` `reverse_proxy:`, role
  `synology_app_portal`):
  - `s3-admin.e4e.ucsd.edu:443` (HTTPS) → `127.0.0.1:8080` (garage-ui)
  - `s3.e4e.ucsd.edu:443` (HTTPS) → `127.0.0.1:3900` (Garage S3 API)
- **TLS** (`spec/e4e-nas/certificates.yml` `sans:`, role
  `synology_certificate`): `s3-admin.e4e.ucsd.edu` + `s3.e4e.ucsd.edu` are SANs
  on the host LE cert. Both names must resolve to the NAS and be HTTP-01
  reachable on `:80` for LE issuance.
- **Firewall**: `:443` is already allowed by the `geoip-US-floor` / trusted-net
  rules in `spec/e4e-nas/security.yml` — no new rule.

> First-apply caveats (no API to dry-run cleanly): the AppPortal field shape is
> a discovery best-guess (run `apply_app_portal.py reverse-proxy --check` first),
> and the LE `SAN_list` param name in `apply_certificate.py` is unverified —
> confirm the issued cert's SANs after the first apply.

## 5. Deploy the garage role — targeted, secrets materialized from OpenBao

> Use **`--tags=synology_garage`** (cluster + UI). Do **not** run the full
> playbook here — that does a destructive declarative sync of the whole NAS,
> gated on the full bring-up (`docs/e4e-nas-dsm.md`).

```bash
export VAULT_ADDR=https://krg-vault.ucsd.edu:8200
export VAULT_TOKEN="$(bao write -field=token auth/approle/login \
  role_id="$(< /var/lib/krg-admin/.secrets/openbao-role-id)" \
  secret_id="$(< /var/lib/krg-admin/.secrets/openbao-secret-id)")"

umask 077
vars="$(mktemp -t garage-vars.XXXXXX.json)"
trap 'shred -u "$vars" 2>/dev/null || rm -f "$vars"' EXIT
g="$(bao kv get -format=json secret/e4e-nas/garage)"
o="$(bao kv get -format=json secret/e4e-nas/garage-ui-oidc)"
jq -n \
  --argjson g "$(jq '.data.data' <<<"$g")" \
  --argjson o "$(jq '.data.data' <<<"$o")" \
  '{
    garage_rpc_secret:            $g.rpc_secret,
    garage_admin_token:           $g.admin_token,
    garage_metrics_token:         $g.metrics_token,
    garage_ui_oidc_client_secret: $o.client_secret
  }' > "$vars"

cd "$(git rev-parse --show-toplevel)/ansible/synology"
TAGS=synology_certificate,synology_garage,synology_app_portal
ansible-playbook playbook.yml --tags="$TAGS" --check --diff -e @"$vars"   # dry run
ansible-playbook playbook.yml --tags="$TAGS"               -e @"$vars"    # apply
```

This issues/updates the host cert with the new SANs (`synology_certificate`),
bumps Garage `v1.1.0 → v2.3.0` (data + layout compatible; cluster is fresh) and
brings up the `garage-ui` container (`synology_garage`), and creates the
`s3-admin.e4e.ucsd.edu` + `s3.e4e.ucsd.edu` reverse proxies
(`synology_app_portal`). Tag-scoped, so it does **not** trigger the full-NAS
destructive sync.

## 6. Verify

```bash
ssh e4e-admin@e4e-nas.ucsd.edu 'sudo /usr/local/bin/docker ps \
  --format "{{.Names}}\t{{.Image}}\t{{.Status}}"'
#   expect: garage  dxflrs/garage:v2.3.0  Up …
#           garage-ui  noooste/garage-ui:0.6.1  Up …
```

Browser: `https://s3-admin.e4e.ucsd.edu` → Authentik login → confirm the
`Garage Admins` gate → list/create a bucket → upload a test file. The S3 API
answers at `https://s3.e4e.ucsd.edu` (e.g. `aws --endpoint-url …`).

## After bring-up — CD takes over

Once validated, the same secrets flow unattended via
`deploy/deploy-ansible.sh` (AppRole login → `bao kv get` → extra_vars). The
synology CD stage stays gated on `DEPLOY_SYNOLOGY=true` until the **full** NAS
bring-up clears and the remaining NAS secrets are seeded into OpenBao
(#110) — it runs the whole playbook (destructive sync), unlike this targeted
deploy.
