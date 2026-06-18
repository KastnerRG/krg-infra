# ── AD-backed authorization for the lab PKI ──────────────────────────────────
#
# Hooks the OpenBao PKI (pki.tf) into Active Directory (KRG.LOCAL): a human logs
# into OpenBao with their AD account and their AD GROUP MEMBERSHIP decides which
# pki_int issuing roles they may use. This is the same "AD group is the authority"
# model already used for host logins (nix krg.adClient) and Grafana SSO — there is
# no second, cert-only identity namespace to keep in sync.
#
# Scope split (deliberate):
#   * MACHINES keep authenticating with AppRole (main.tf) — a host is not an AD
#     user. The Temporal frontend/UI and the tofu runner issue via krg-prod/
#     krg-deploy AppRole grants, unchanged.
#   * HUMANS authenticate here (ldap) to mint their own short-lived CLIENT certs
#     (the `user` role in pki.tf), which carry their AD UPN as a SAN.
#
# BOOTSTRAP NOTE (chicken-and-egg): this binds over LDAPS, and the DC's LDAPS cert
# would ideally be issued by THIS CA — but that's circular. So `ldap_ca_cert` is
# whatever currently signs the DC's LDAPS endpoint (Samba's self-signed cert at
# first); once the chain is up you can re-issue the DC cert from pki_int and swap
# this to the lab root. insecure_tls stays false — we always verify the DC.

resource "vault_ldap_auth_backend" "ad" {
  path        = "ldap"
  description = "KRG.LOCAL Active Directory — authorizes human PKI cert issuance"

  url          = var.ldap_url
  binddn       = var.ldap_binddn
  bindpass     = var.ldap_bindpass # sensitive — supply via TF_VAR_ldap_bindpass
  certificate  = var.ldap_ca_cert  # PEM that verifies the DC's LDAPS cert
  insecure_tls = false
  starttls     = false # url is ldaps:// (port 636), not StartTLS on 389

  # AD search shape (KRG.LOCAL). userattr=sAMAccountName so people log in with
  # their plain username; upndomain lets `user@krg.local` binds work too.
  userdn      = var.ldap_userdn
  userattr    = "sAMAccountName"
  upndomain   = var.ldap_upndomain
  groupdn     = var.ldap_groupdn
  groupattr   = "cn"
  groupfilter = var.ldap_groupfilter

  # AD group names like "Domain Admins" differ only in case across tools — fold
  # case so the vault_ldap_auth_backend_group bindings below match reliably.
  case_sensitive_names = false
}

# One policy per AD group, granting `pki_int/issue/<role>` for exactly the roles
# that group is mapped to (least-privilege, enumerated — same pattern as the
# authentik_secret_rules / pki_*_rules blocks in main.tf). Reading the CA chain
# needs no grant (the /ca and /crl endpoints are public, see pki.tf config_urls).
resource "vault_policy" "pki_ad_group" {
  for_each = var.pki_ad_group_roles
  name     = "pki-ad-${replace(lower(each.key), " ", "-")}"
  policy = join("\n\n", [
    for role in each.value :
    "path \"pki_int/issue/${role}\" {\n  capabilities = [\"create\", \"update\"]\n}"
  ])
}

# Bind each AD group to its generated policy. A member of the AD group inherits
# the policy on login — add a group to var.pki_ad_group_roles and it lights up
# here; no per-user OpenBao config.
resource "vault_ldap_auth_backend_group" "pki" {
  for_each  = var.pki_ad_group_roles
  backend   = vault_ldap_auth_backend.ad.path
  groupname = each.key
  policies  = [vault_policy.pki_ad_group[each.key].name]
}
