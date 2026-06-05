# LDAP source: federate Authentik with the KRG Samba AD (realm KRG.LOCAL).
# AD accounts log in to all Authentik-integrated apps via SSO.
#
# TLS: StartTLS with no cert verification for now — Samba CA cert not yet
# imported into Authentik. Upgrade to full LDAPS + cert verify once the CA
# is imported (see docs/joining-a-host-to-the-domain.md).
resource "authentik_source_ldap" "samba_ad" {
  name    = "KRG Samba AD"
  slug    = "krg-samba-ad"
  enabled = true

  server_uri = "ldap://krg-ldap.ucsd.edu"
  start_tls  = true

  bind_cn       = "CN=authentik-bind,CN=Users,DC=KRG,DC=LOCAL"
  bind_password = var.ldap_bind_password
  base_dn       = "DC=KRG,DC=LOCAL"

  # Samba AD default provisioning puts built-in groups (Domain Admins, Domain
  # Users, Schema Admins, …) under CN=Users — NOT under a CN=Groups OU. Pointing
  # group search at CN=Users mirrors what SSSD uses on the fleet (see
  # nix/modules/sssd-ad-client.nix) and is required for the
  # 'Domain Admins → GrafanaAdmin' JMESPath in terraform/grafana/sso.tf to
  # find anything. group_object_filter (objectClass=group) keeps users out
  # of the group result set even though they share a DN.
  additional_user_dn  = "CN=Users"
  additional_group_dn = "CN=Users"

  user_object_filter      = "(objectClass=person)"
  group_object_filter     = "(objectClass=group)"
  # Resolve NESTED AD groups: read membership from the user's `memberOf` with
  # AD's LDAP_MATCHING_RULE_IN_CHAIN OID (transitive/recursive), instead of each
  # group's flat `member`. So a user in a child group (e.g. "E4E Admins" nested
  # in "E4E Garage Admins") gets BOTH in their groups claim — apps can key off
  # the parent group alone. Samba (krg-ldap) confirmed to honor the in-chain rule
  # 2026-06-04. NOTE: this governs membership resolution for the WHOLE source
  # (every app); it's a superset of `member` (direct + nested), so grafana's
  # "Domain Admins" etc. still resolve. Re-sync the source after applying.
  group_membership_field  = "memberOf:1.2.840.113556.1.4.1941:"
  object_uniqueness_field = "objectSid"

  # 7 user property mappings — matches the live source config (screenshot).
  property_mappings = [
    data.authentik_property_mapping_source_ldap.dn_user_path.id,
    data.authentik_property_mapping_source_ldap.mail.id,
    data.authentik_property_mapping_source_ldap.name.id,
    data.authentik_property_mapping_source_ldap.ad_given_name.id,
    data.authentik_property_mapping_source_ldap.ad_sam_account_name.id,
    data.authentik_property_mapping_source_ldap.ad_sn.id,
    data.authentik_property_mapping_source_ldap.ad_upn.id,
  ]

  # 2 group property mappings: the built-in "name" mapping, plus the
  # Domain-Admins → is_superuser mapping (groups.tf) that makes AD "Domain
  # Admins" members Authentik superusers (#143).
  property_mappings_group = [
    data.authentik_property_mapping_source_ldap.name.id,
    authentik_property_mapping_source_ldap.group_superuser.id,
  ]

  sync_users  = true
  sync_groups = true

  # Update Authentik's internal password hash on login via this source, so
  # Authentik can authenticate the user (as a fallback) when LDAP is down.
  password_login_update_internal_password = true

  # User password writeback: when a user changes their password in Authentik,
  # write it back to AD. Was off (false) — that's why password changes didn't
  # propagate. Two prerequisites:
  #   - the `authentik-bind` account must have password-reset rights on
  #     KRG.LOCAL user objects (grant on krg-ldap), else writeback silently fails;
  #   - Authentik allows this on exactly ONE LDAP source — now satisfied (the
  #     duplicate "KRG Active Directory" source was removed).
  sync_users_password = true

  # Delete Authentik users/groups that were synced from this source but are now
  # missing from the directory. ⚠️ DESTRUCTIVE: a partial/broken sync (bind can't
  # see an OU, filter too narrow, LDAP hiccup) would PRUNE real accounts.
  #
  # HELD OFF (false) until a clean full sync is verified: user/group syncing was
  # found DISABLED on the live source (drift), and there are orphaned users from
  # the just-removed duplicate source. Enabling prune in the same apply that
  # re-enables syncing would risk pruning during that messy first sync. Flip to
  # `true` in a follow-up once a full sync is confirmed to re-claim everyone.
  delete_not_found_objects = false
}
