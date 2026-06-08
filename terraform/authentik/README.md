# terraform/authentik — Authentik SSO config

Manage **Authentik's objects** declaratively with the `goauthentik/authentik`
provider, instead of click-ops in the Authentik admin UI.

> Built out: applications + their OAuth2/OIDC and proxy providers
> (`applications_krg.tf`, `applications_e4e.tf`), the Samba AD LDAP source +
> superuser mapping (`ldap.tf`, `groups.tf`), the proxy outpost (`outpost.tf`),
> and the OpenBao secret writeback (`vault_secrets.tf`, `roster_secrets.tf`).
> State, secrets, and apply discipline below still apply.

**Scope: config, not deployment.** Authentik runs as a Docker Compose stack on
**krg-prod** (`nix/docker-compose/krg-prod/compose.authentik.yml`). That stays.
This target manages what lives *inside* Authentik:

- Applications + their OAuth2/OIDC and proxy providers
  (`applications_krg.tf`, `applications_e4e.tf`)
- The Samba AD LDAP **source** (`ldap.tf`) — federates `KRG.LOCAL`; default
  flows/cert are read-only `data` lookups (`data.tf`), not managed here
- Group property mappings: AD `Domain Admins` → Authentik `is_superuser`
  (`groups.tf`). Groups are **AD-sourced** via the LDAP source, not local
  `authentik_group` resources
- A proxy **outpost** (`outpost.tf`) and the generated-OIDC-secret writeback
  into OpenBao (`vault_secrets.tf`, `roster_secrets.tf`)

## Prerequisites before this can plan

1. Authentik reachable (its URL on krg-prod).
2. An **API token** — the bootstrap `akadmin` token or a dedicated
   service-account token (stored in OpenBao at
   `secret/krg-deploy/authentik-admin-token`).
3. A reachable **OpenBao** server — this workspace writes the generated OIDC
   client secrets back into it for downstream workspaces (`grafana/`) to read.

Three providers are configured (`providers.tf`): `authentik` (the objects),
`vault` (OpenBao secret writeback), and `random` (`roster_secrets.tf`). Apply
needs these env vars:

```bash
export TF_VAR_authentik_token="<authentik API token>"
export TF_VAR_ldap_bind_password="<authentik-bind password>"
export TF_VAR_vault_addr="https://krg-vault.ucsd.edu:8200"
export VAULT_TOKEN="<vault token>"
tofu init && tofu apply
```

## Notes

- Tokens (and any created provider client secrets) land in **state** → this is
  exactly why state encryption / a backend matters before going live (see
  [`../README.md`](../README.md#secrets--state-shared-rules)).
- Natural SSO loop: Authentik becomes the **OIDC provider for OpenBao** auth
  (`../openbao/`), and can front AD identity from `KRG.LOCAL`.
