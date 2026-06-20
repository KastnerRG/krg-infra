# Proxmox login via an Authentik LDAP outpost.
#
# Proxmox VE (web UI + the mobile/CLI apps) authenticates against a PVE *LDAP*
# realm that points at an Authentik LDAP outpost — NOT raw krg-ldap. Why through
# Authentik: Authentik's LDAP source FLATTENS nested AD groups during sync, so a
# user who is in `proxmox-admins` only via `Domain Admins` (nested) appears as a
# DIRECT member in Authentik's view. PVE can't expand nested groups itself, so it
# reads the already-flattened directory the outpost serves. (OIDC was dropped
# because the apps can't do the browser redirect — LDAP is a plain bind, so they
# work; Authentik stays in the path, which is fine.)
#
# Pieces: the LDAP provider + an application binding it + a dedicated LDAP outpost
# (manual container — see nix/docker-compose/krg-prod/compose.authentik.yml) + a
# read-only service account PVE binds with. The provider serves a tree under
# base_dn with users at ou=users and groups at ou=groups.
#
# ⚠ BRING-UP: several values here can only be confirmed against the running outpost
# (the exact tree/attrs Authentik serves, the search-permission codename, the
# service-account password field). They're marked ⚠; validate with `ldapsearch`
# against the outpost before wiring PVE. See docs/proxmox-auth.md.

locals {
  proxmox_ldap_base_dn = "DC=krg,DC=ucsd,DC=edu"
}

resource "authentik_provider_ldap" "proxmox" {
  name        = "Provider for Proxmox LDAP"
  base_dn     = local.proxmox_ldap_base_dn
  bind_flow   = data.authentik_flow.default_authentication.id
  unbind_flow = data.authentik_flow.default_invalidation.id
  # mfa_support DEFAULTS TO true — explicitly off (password-only, per the auth
  # decision). Flip to true later to require TOTP (append code / app-password).
  mfa_support = false
  # bind_mode/search_mode left at the provider default ("direct") so each bind +
  # search is validated live against Authentik.
}

# Application backing the LDAP provider. No launch URL / group — it's NOT a
# dashboard tile (the provider-less `proxmox` app in applications_krg.tf is the
# tile). Authentik requires an application per provider.
resource "authentik_application" "proxmox_ldap" {
  name              = "Proxmox LDAP"
  slug              = "proxmox-ldap"
  protocol_provider = authentik_provider_ldap.proxmox.id
  meta_description  = "LDAP directory for the Proxmox VE realm (not a user-facing app)"
}

# Dedicated LDAP outpost. LDAP can't use the embedded/proxy outpost — it needs its
# own container (ghcr.io/goauthentik/ldap), run manually in the krg-prod compose
# stack. Token retrieval is MANUAL, same as the proxy outpost (outpost.tf): after
# apply, Admin → Outposts → "View token", store at
# secret/krg-prod/authentik-ldap-outpost-token, render to the env file the
# container reads.
resource "authentik_outpost" "ldap" {
  name               = "authentik LDAP Outpost"
  type               = "ldap"
  protocol_providers = [authentik_provider_ldap.proxmox.id]

  config = jsonencode({
    authentik_host          = var.authentik_url
    authentik_host_insecure = false
    log_level               = "info"
  })
}

# ── Bind/search service account ─────────────────────────────────────────────────
# PVE binds as this account (cn=svc-pve-ldap,ou=users,<base_dn>) to enumerate the
# proxmox-admins group + members during realm sync. Login itself binds as the END
# user, not this. Password generated here, written to OpenBao for the pve_ldap
# ansible role to consume.
resource "random_password" "svc_pve_ldap" {
  length  = 32
  special = false # avoid LDAP/shell-quoting surprises in the bind password
}

# ⚠ `password` is assumed settable on authentik_user; if the apply rejects it,
# switch to an app-password token (authentik_token) and bind with that instead.
resource "authentik_user" "svc_pve_ldap" {
  username = "svc-pve-ldap"
  name     = "Proxmox LDAP bind (read-only search)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  password = random_password.svc_pve_ldap.result
}

# Full-directory search permission so the bind account can enumerate users/groups
# (a plain account only sees itself). ⚠ Confirm the permission codename matches the
# running Authentik (Admin → search the LDAP "Search full LDAP directory"
# permission); adjust if the apply 400s on an unknown permission.
resource "authentik_rbac_permission_user" "ldap_search" {
  user       = authentik_user.svc_pve_ldap.id
  permission = "authentik_providers_ldap.search_full_directory"
}

# Bind creds for PVE — read by deploy/deploy-ansible.sh (krg-deploy AppRole) and
# passed to the pve_ldap role. Path enumerated in terraform/openbao/main.tf.
resource "vault_kv_secret_v2" "proxmox_ldap_bind" {
  mount = "secret"
  name  = "krg-prod/proxmox-ldap-bind"
  data_json = jsonencode({
    bind_dn  = "cn=${authentik_user.svc_pve_ldap.username},ou=users,${local.proxmox_ldap_base_dn}"
    base_dn  = local.proxmox_ldap_base_dn
    password = random_password.svc_pve_ldap.result
  })
}
