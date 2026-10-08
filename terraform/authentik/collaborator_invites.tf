# Per-tenant collaborator invites — one REUSABLE self-serve enrollment link per
# partner org (ADR 0013 §4).
#
# Each entry below is an external partner org (the "tenant" a collaborator joins)
# under one of our multitenant apps. It mints ONE multi-use Authentik invitation
# bound to the collaborator enrollment flow (collaborator_enrollment.tf), whose
# fixed_data stamps every account created through it with
#
#     attributes.tenant = <app tenant>   (e.g. "fishsense" — the access gate,
#                                          fishsense_collaborators.tf)
#     attributes.org    = <map key>      (the partner org — the `org` OIDC claim
#                                          the app keys its own isolation on)
#
# The org hands the link to its own people, who self-serve an Authentik-LOCAL,
# `external`, email-verified account — no AD account, no repo change per person.
# Accounts are NOT put in the AD-synced app group (e.g. "FishSense"): the LDAP
# sync owns those groups' membership. Tenant membership is the attribute above.
#
# The tenant/org values are tamper-proof: the invitation stage merges fixed_data
# into prompt_data server-side, and the prompt stage pins hidden fields to that
# server value (an edited form submission is overwritten), so a link holder can't
# re-label themselves into another org.
#
# Bounds on a reusable link (it IS a bearer credential until it expires):
#   - hard `expires` — renew by bumping the date (an UPDATE: same link survives);
#   - email verification before the account activates;
#   - revoke early by deleting the entry (destroys the invite; accounts already
#     made stay — deactivate those in Authentik → Directory → Users, filter on
#     attribute org). To rotate a leaked link: delete the entry, apply, re-add.
#
# Once `expires` passes, the entry drops out of the active set below and the
# invite is destroyed — or, if Authentik's expiry cleanup reaped it first, restapi
# treats the 404 as already-gone. Either way an expired entry is a no-op, not a
# fresh dead invite every deploy and not a red deploy. Prune expired entries at leisure.
#
# The link lands in OpenBao, never in git:
#   bao kv get -field=url secret/krg-prod/authentik-managed/collaborator-invites/<org>
# (covered by the krg-prod/authentik-managed glob — no terraform/openbao apply.)
#
# WHY restapi: goauthentik ships no invitation resource, so the invite is driven
# through Authentik's REST API (/api/v3/stages/invitation/invitations/) with the
# same API token as the authentik provider (providers.tf). One-off, per-person,
# single-use invites are still minted in the UI (README "Minting an invite").

locals {
  # org (map key, slug: lowercase/digits/hyphens) → its tenant + link expiry (UTC).
  collaborator_invites = {
    # FishSense partner org; link issued 2026-10-07 for 90 days.
    conservation-angler = {
      tenant  = "fishsense"
      expires = "2027-01-05T00:00:00Z"
    }
  }

  active_collaborator_invites = {
    for org, inv in local.collaborator_invites : org => inv
    if timecmp(inv.expires, plantimestamp()) > 0
  }
}

resource "restapi_object" "collaborator_invite" {
  for_each = local.active_collaborator_invites

  # Authentik's API requires the trailing slash (Django APPEND_SLASH can't redirect
  # a POST/PUT/DELETE), so every verb's path is spelled out rather than defaulted
  # to `path/{id}`.
  path         = "/stages/invitation/invitations"
  create_path  = "/stages/invitation/invitations/"
  read_path    = "/stages/invitation/invitations/{id}/"
  update_path  = "/stages/invitation/invitations/{id}/"
  destroy_path = "/stages/invitation/invitations/{id}/"
  id_attribute = "pk" # = the invite token (?itoken=)

  # The server adds pk / created_by / flow_obj; only the fields we set are managed.
  ignore_server_additions = true

  data = jsonencode({
    name       = "collab-${each.value.tenant}-${each.key}" # SlugField
    flow       = authentik_flow.collaborator_enrollment.uuid
    single_use = false # THE reusable switch — one link per org, not per person
    expires    = each.value.expires
    # Keys MUST match the hidden prompt fields' field_key (collaborator_enrollment.tf).
    fixed_data = {
      "attributes.tenant" = each.value.tenant
      "attributes.org"    = each.key
    }
  })
}

resource "vault_kv_secret_v2" "collaborator_invite" {
  for_each = restapi_object.collaborator_invite
  mount    = "secret"
  name     = "krg-prod/authentik-managed/collaborator-invites/${each.key}"
  data_json = jsonencode({
    url     = "${var.authentik_url}/if/flow/${authentik_flow.collaborator_enrollment.slug}/?itoken=${each.value.id}"
    tenant  = local.active_collaborator_invites[each.key].tenant
    org     = each.key
    expires = local.active_collaborator_invites[each.key].expires
  })
}
