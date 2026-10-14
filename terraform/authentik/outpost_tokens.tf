# Outpost API tokens — minted in IaC, no manual "View token" step.
#
# An EXTERNAL outpost container (authentik_proxy, authentik_ldap in
# nix/docker-compose/krg-prod/compose.authentik.yml) authenticates to the Authentik
# core with an API token belonging to the outpost's service account. Authentik
# auto-creates that SA and a token when the outpost is created — but the token's
# value is only viewable once, in the UI, so the repo used to seed it into OpenBao
# by hand on every bring-up. This replaces that: for each managed outpost we mint
# our OWN api token for its SA with `retrieve_key`, and write it to OpenBao under
# the authentik-managed/* sub-path — the glob krg-deploy may write with NO
# terraform/openbao policy change (terraform/openbao/main.tf). The consuming host's
# vault-agent renders each into the env file its container reads. Adding another
# outpost is a one-line addition to managed_outposts below (its OpenBao leaf is derived
# from the key: krg-prod/authentik-managed/<key>-outpost-token).
#
# WHY NOT self-mint these early (the way terraform/secrets self-mints the OIDC
# client_secrets and DB passwords before phase 2): authentik_token.key is
# provider-READ-ONLY — Authentik generates it. A token can therefore only exist once
# Authentik is up AND the outpost record exists, i.e. when THIS target applies
# (phase 3), AFTER krg-prod's fail-closed vault-agent renders (phase 2). That
# inversion can't be dissolved, only converged: the outpost-token renders on krg-prod
# are the ONLY secrets allowed to be absent at phase 2 (krg.vaultAgent …
# errorOnMissingKey = false). A missing token fails LOUD — the outpost can't connect
# (visible in Admin → Outposts, and as a login failure) — never silently-wrong, and
# deploy/deploy-rerender-secrets.sh re-renders krg-prod AFTER this phase so a
# from-scratch deploy still converges in a single run.
#
# ⚠ CUTOVER (one-time, proxy only): the proxy outpost token used to live at the
# pre-glob path secret/krg-prod/authentik-outpost-token. Moving it to the glob path
# means that path is empty until THIS target first mints it, so the FIRST deploy
# after this lands would briefly drop live forward-auth SSO between phase 2 (empty
# render) and phase 3.5 (re-render). To avoid the blip, apply terraform/authentik
# ONCE manually before the krg-prod rebuild so the new path is already populated.
# Steady state is seamless. The old path is then orphaned (harmless; delete it with a
# privileged token if you want it gone).

locals {
  # outpost key -> the authentik_outpost resource id (dashed uuid). The key names both the
  # token identifier and the OpenBao leaf (vault_kv_secret_v2.outpost_token below).
  managed_outposts = {
    proxy = authentik_outpost.proxy.id
    ldap  = authentik_outpost.ldap.id
  }
}

# Each outpost's service account. Authentik names it ak-outpost-<outpost UUID HEX>
# (no dashes — `self.uuid.hex` in authentik/outposts/models.py), while the resource
# id is the DASHED uuid, so strip the dashes. depends_on defers these lookups to
# APPLY time: the SAs are created in each outpost's post-save, so they don't exist
# during the plan of a from-scratch apply.
data "authentik_user" "outpost_sa" {
  for_each   = local.managed_outposts
  username   = "ak-outpost-${replace(each.value, "-", "")}"
  depends_on = [authentik_outpost.proxy, authentik_outpost.ldap]
}

# A non-expiring api token per outpost SA. `retrieve_key` reads the generated key
# back into (encrypted) state so we can write it to OpenBao. A second token on the
# SA is harmless — the auto-created one stays valid and unused; the outpost accepts
# any api token of its own SA.
resource "authentik_token" "outpost" {
  for_each     = local.managed_outposts
  identifier   = "krg-${each.key}-outpost-token"
  user         = data.authentik_user.outpost_sa[each.key].id
  intent       = "api"
  expiring     = false
  retrieve_key = true
  description  = "${each.key} outpost API token (managed by terraform/authentik/outpost_tokens.tf; rendered by the consuming host's vault-agent)"
}

# Write-back to the per-outpost OpenBao leaf, krg-prod/authentik-managed/<key>-outpost-token —
# all render on krg-prod (krg.vaultAgent), under the authentik-managed/* glob, field `token`. No
# openbao policy change — the prefix is already in the krg-deploy writer set
# (terraform/openbao/main.tf). (The fishsense co-located outpost, which wrote to
# tenants/fishsense/oidc/proxy-outpost-token, was retired in #552: fishsense-services
# validates bearer tokens in-app.) A non-standard location would need an override map again.
#
# RETIRING an outpost: a plain destroy of this leaf only SOFT-deletes its latest version —
# metadata and older versions (still-readable credentials) linger, as #552 left behind. Either
# set `delete_all_versions = true` on the leaf and apply BEFORE removing it, or follow the
# destroy with `bao kv metadata delete secret/<path>`. (Not set here by default: toggling it
# makes the provider rewrite the live secret as a new version.)
resource "vault_kv_secret_v2" "outpost_token" {
  for_each = local.managed_outposts
  mount    = "secret"
  name     = "krg-prod/authentik-managed/${each.key}-outpost-token"
  data_json = jsonencode({
    token = authentik_token.outpost[each.key].key
  })
}
