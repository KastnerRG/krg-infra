# ── Per-application access restriction by AD group ───────────────────────────────
# By default an Authentik application with NO policy bindings is visible/launchable
# to every authenticated user. These bindings flip the listed apps to "members of
# the named AD group(s) only" — they gate BOTH the dashboard tile and the launch
# authorization (so the provider-less Proxmox link tile is hidden too).
#
# Groups are AD-SOURCED (synced by the LDAP source, ldap.tf `sync_groups = true`);
# we LOOK THEM UP by name rather than create local groups (see groups.tf). A lookup
# on a non-existent group fails `tofu apply`, so every name below must already exist
# in KRG.LOCAL (spec/krg-ad/groups.yml). "Domain Admins" is the builtin AD group.
#
# Multiple groups on one app are OR-ed: the application's policy_engine_mode defaults
# to "any", so a user in ANY listed group is authorized.

locals {
  # app local-name → the AD group names allowed to access it.
  app_group_access = {
    grafana   = ["Domain Admins", "Waiter", "KastnerML"]
    guacamole = ["Domain Admins", "Waiter", "KastnerML"]
    fleet     = ["Domain Admins"]  # device control plane — admins only (resolves the hardening follow-up in applications_e4e.tf)
    proxmox   = ["proxmox-admins"] # space-free name on purpose (see groups.tf / spec)
    # LOAD-BEARING: this binding is the ENTIRE Incus access control. Incus 7.2 can't
    # restrict an OIDC identity (no `incus auth`, and the scriptlet authorizer can't see
    # groups), so any user who completes the incus OIDC flow gets FULL platform admin
    # (confirmed live). This gate is what limits that to Domain Admins — do NOT remove it
    # without a replacement authorizer. Project-scoped non-admin access is tracked in #417.
    incus = ["Domain Admins"]
    # Superset gates in-app roles on the same three groups via its OIDC `groups`
    # claim (AUTH_ROLES_MAPPING); a FishSense member without a role group gets no
    # Superset role, so scope the tile/launch to exactly the role-holders. OR-ed
    # (policy_engine_mode "any"), so membership in any one is enough.
    fishsense_analytics    = ["fishsense-superset-admin", "fishsense-superset-editor", "fishsense-superset-viewer"]
    fishsense_oauth        = ["FishSense"]
    fishsense_orchestrator = ["FishSense-Prod-Admins"] # FishSense API — prod admins only (space-free AD name; see groups.yml)
    e4e_nas                = ["E4E-NAS"]               # NAS SSO tile visible only to NAS-access group (matches the nix krg.nasMount sudo gate)
    garage_ui              = ["E4E-NAS"]               # Garage (S3-on-NAS) admin/data browser — same NAS-access gate as e4e_nas
    # Both groups exist in KRG.LOCAL (spec/krg-ad/groups.yml) and must be synced into
    # Authentik before apply. The label_studio_groups SAML mapping (label_studio.tf) also
    # emits both names to Label Studio, where they map to org roles — this binding is the
    # outer tile/launch gate; that attribute is the in-app role gate (complementary).
    label_studio = ["Label Studio Users", "Label Studio Admins"]
  }

  # app local-name → its application UUID (the policy-binding target).
  app_access_uuids = {
    grafana                = authentik_application.grafana.uuid
    guacamole              = authentik_application.guacamole.uuid
    fleet                  = authentik_application.fleet.uuid
    proxmox                = authentik_application.proxmox.uuid
    incus                  = authentik_application.incus.uuid
    fishsense_analytics    = authentik_application.fishsense_analytics.uuid
    fishsense_oauth        = authentik_application.fishsense_oauth.uuid
    fishsense_orchestrator = authentik_application.fishsense_orchestrator.uuid
    e4e_nas                = authentik_application.e4e_nas.uuid
    garage_ui              = authentik_application.garage_ui.uuid
    label_studio           = authentik_application.label_studio.uuid
  }

  # Flatten to one binding per (app, group) pair, keyed "app:group".
  app_group_bindings = merge([
    for app_key, groups in local.app_group_access : {
      for idx, grp in groups : "${app_key}:${grp}" => {
        target = local.app_access_uuids[app_key]
        group  = grp
        order  = idx
      }
    }
  ]...)

  # Unique AD group names to resolve to Authentik group IDs.
  access_group_names = toset([for b in values(local.app_group_bindings) : b.group])
}

data "authentik_group" "access" {
  for_each      = local.access_group_names
  name          = each.value
  include_users = false # don't pull member lists into tofu state
}

resource "authentik_policy_binding" "app_group_access" {
  for_each = local.app_group_bindings
  target   = each.value.target
  group    = data.authentik_group.access[each.value.group].id
  order    = each.value.order
}

# ── Pending: groups that don't exist in KRG.LOCAL yet (skipped per request) ───────
# Uncomment each block once the named group is created in AD (spec/krg-ad/groups.yml
# + ansible krg-ad apply). Until then these apps stay open to all authenticated users.
#
# Temporal → "Temporal Admins" (closest existing is "Temporal Users"):
#   data "authentik_group" "temporal_admins" {
#     name          = "Temporal Admins"
#     include_users = false
#   }
#   resource "authentik_policy_binding" "temporal_access" {
#     target = authentik_application.temporal.uuid
#     group  = data.authentik_group.temporal_admins.id
#     order  = 0
#   }
#
# E4E NAS + E4E Garage UI → "E4E-NAS": DONE (in app_group_access above — the same AD
# group that gates the kastner-ml krg.nasMount sudo wrapper; keeps the NAS SSO tiles and
# the mount access consistent). The group must exist in KRG.LOCAL (spec/krg-ad/groups.yml)
# and be synced into Authentik before `tofu apply`, or the data.authentik_group lookup
# fails. Note garage-ui ALSO enforces admin-vs-read internally via its OIDC `groups` claim
# ("E4E Garage Admins"/"E4E Admins", spec/e4e-nas/garage.yml) — this binding is the outer
# tile/launch gate, that claim is the in-app role gate; they're complementary.
