# fishsense (Incus tenant) — per-tenant Garage object stores for FishSense Mobile sync
# (fishsense-services PLAN.md §9.6/§9.11; its handoff docs/handoff/krg-infra/MOBILE_SYNC.md §2).
#
#   tenants/fishsense/generated/object_stores   {stores_json}
#       stores_json = JSON {"<tenant-slug>": {bucket, access_key_id, secret_access_key}}
#       — the contract fishsense-services' API reads (tenant_stores.py), soft-rendered
#       to object-stores/stores.json by deploy/incus/secrets.nix. ONE secret for every
#       tenant, so the slot's agent needs no `list`. A tenant with no entry can't sync.
#
# DERIVED, not generated: the tenants are the `fishsense-tenant-<slug>` keys in
# spec/e4e-nas/garage.yml (the single place a tenant's bucket + key are declared),
# and each credential is the create-once value the control node provisions at
# secret/e4e-nas/garage-keys/<key> in Phase 1 (deploy/deploy-ansible.sh) — BEFORE
# this target runs in Phase 1.5, so a newly-added key is always readable here. This
# secret holds no value of its own: recreating it is harmless (it re-derives the same
# JSON), unlike the generate-once secrets beside it.
#
# Under tenants/+/generated — krg-deploy's writer glob (terraform/openbao/main.tf), so
# no openbao apply; the tenant AppRole reads it via secret/data/tenants/fishsense/*.
# Reading secret/data/e4e-nas/garage-keys/* is already in the krg-deploy policy.
#
# After a tenant is added, fishsense-services' API reads the file only at start: run
# `fishsense-services-api add-tenant` on the slot, then restart openbao-agent and
# recreate the `api` container (the services handoff's "Adding a tenant later").

locals {
  fishsense_tenant_key_prefix = "fishsense-tenant-"
  # slug → Garage key name, e.g. "conservation-angler" → "fishsense-tenant-conservation-angler".
  # The key and its bucket share the name (the spec pairs them one-to-one).
  fishsense_tenant_keys = {
    for k in yamldecode(file("${path.module}/../../spec/e4e-nas/garage.yml")).keys :
    trimprefix(k.name, local.fishsense_tenant_key_prefix) => k.name
    if startswith(k.name, local.fishsense_tenant_key_prefix)
  }
}

data "vault_kv_secret_v2" "fishsense_tenant_garage_key" {
  for_each = local.fishsense_tenant_keys
  mount    = "secret"
  name     = "e4e-nas/garage-keys/${each.value}"
}

resource "vault_kv_secret_v2" "fishsense_object_stores" {
  mount = "secret"
  name  = "tenants/fishsense/generated/object_stores"
  data_json = jsonencode({
    stores_json = jsonencode({
      for slug, key in local.fishsense_tenant_keys : slug => {
        bucket            = key
        access_key_id     = data.vault_kv_secret_v2.fishsense_tenant_garage_key[slug].data["access_key_id"]
        secret_access_key = data.vault_kv_secret_v2.fishsense_tenant_garage_key[slug].data["secret_access_key"]
      }
    })
  })
}
