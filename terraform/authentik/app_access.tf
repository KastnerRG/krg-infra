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
    incus                  = ["Domain Admins"]
    fishsense_analytics    = ["FishSense"]
    fishsense_oauth        = ["FishSense"]
    fishsense_orchestrator = ["FishSense"]
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
# E4E Garage UI + E4E NAS → "Engineers for Exploration NAS"
# (closest existing: "Engineers for Exploration", "E4E Admin", "E4E Garage Admins"):
#   data "authentik_group" "e4e_nas" {
#     name          = "Engineers for Exploration NAS"
#     include_users = false
#   }
#   resource "authentik_policy_binding" "garage_ui_access" {
#     target = authentik_application.garage_ui.uuid
#     group  = data.authentik_group.e4e_nas.id
#     order  = 0
#   }
#   resource "authentik_policy_binding" "e4e_nas_access" {
#     target = authentik_application.e4e_nas.uuid
#     group  = data.authentik_group.e4e_nas.id
#     order  = 0
#   }
