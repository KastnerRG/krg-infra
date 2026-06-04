# terraform/authentik — Authentik SSO config

Manage **Authentik's objects** declaratively with the `goauthentik/authentik`
provider, instead of click-ops in the Authentik admin UI.

> This workspace was scaffolded by PR #8 (this PR); the actual `.tf`
> resources (applications/providers/flows/groups, the LDAP outpost, the
> OpenBao integration) live in PR #81 (`split 4/4`). State, secrets, and
> apply discipline below still apply.

**Scope: config, not deployment.** Authentik runs as a Docker Compose stack on
**krg-prod** (`nix/docker-compose/krg-prod/compose.authentik.yml`). That stays.
This target manages what lives *inside* Authentik:

- Applications + their providers (OAuth2/OIDC, proxy, SAML)
- Flows / stages / policies
- Groups + property mappings (e.g. mapping `KRG.LOCAL` AD groups → app access)
- Brands, certificates

## Prerequisites before this can plan

1. Authentik reachable (its URL on krg-prod).
2. An **API token** — the bootstrap `akadmin` token (`AUTHENTIK_BOOTSTRAP_TOKEN`)
   or a dedicated service-account token. The provider needs `url` + `token`.

```hcl
# providers.tf
provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token # sensitive
}
```

## Notes

- Tokens (and any created provider client secrets) land in **state** → this is
  exactly why state encryption / a backend matters before going live (see
  [`../README.md`](../README.md#secrets--state-shared-rules)).
- Natural SSO loop: Authentik becomes the **OIDC provider for OpenBao** auth
  (`../openbao/`), and can front AD identity from `KRG.LOCAL`.
