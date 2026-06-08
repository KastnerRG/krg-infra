# Authentik groups are AD-SOURCED. The LDAP source (ldap.tf, `sync_groups = true`)
# pulls KRG.LOCAL groups into Authentik by name; apps key off the AD group NAME
# (grafana → "Domain Admins" in terraform/grafana/sso.tf; garage-ui → "E4E Garage
# Admins"/"E4E Admins" via spec/e4e-nas/garage.yml `ui.oidc.admin_roles`). So DO
# NOT create local `authentik_group` resources for app roles — create the group in
# AD (`samba-tool group add` on krg-ldap), add members there, and let the sync
# bring it in.
#
# SUPERUSER FROM AD (resolves #143): `is_superuser` is Authentik-side metadata the
# LDAP sync does NOT set by default, so "superuser from AD" can't be a plain group
# import — and a local `authentik_group { is_superuser = true }` would be drift
# from AD. Instead we set it with a GROUP property mapping evaluated during every
# sync: it flips `is_superuser` ON for the synced group whose CN is "Domain Admins"
# and OFF for every other group (so the bit can't drift). Members of AD "Domain
# Admins" therefore become Authentik superusers automatically. Wired into the LDAP
# source's `property_mappings_group` in ldap.tf. To grant superuser to another AD
# group later, widen the CN check here rather than creating a local group.
resource "authentik_property_mapping_source_ldap" "group_superuser" {
  name       = "krg: AD Domain Admins → Authentik superuser"
  expression = <<-EOT
    # `ldap` holds the synced GROUP's attributes; `cn` may arrive as a list.
    cn = ldap.get("cn")
    if isinstance(cn, list):
        cn = cn[0] if cn else None
    return {"is_superuser": cn == "Domain Admins"}
  EOT
}
