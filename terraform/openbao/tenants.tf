# Per-tenant OpenBao wiring for the e4e-prod student-project platform (ADR 0008).
#
# Each tenant in `var.tenants` (which MIRRORS the Nix `krg.tenants` roster in
# nix/modules/tenant-platform.nix) gets:
#   - an AppRole `tenant-<name>` — the in-VM vault-agent authenticates with it, and
#     krg-deploy stages its role-id + a minted secret-id into the VM's bootstrap
#     share (the krg-deploy policy already covers `auth/approle/role/+/{role-id,
#     secret-id}`, so no new grant there).
#   - a LEAST-PRIVILEGE policy: mint only its own `tenant-internal` cert (pki.tf) and
#     read only its own KV path. A compromised tenant VM can do neither a fleet-domain
#     cert nor another tenant's secrets.
#
# NOTE: the tenant list is duplicated here and in Nix. A shared source (like
# keys/admins.json / networks/trusted.json) could dedupe it later; kept as a tofu var
# for now since the two layers consume it very differently.

resource "vault_policy" "tenant" {
  for_each = var.tenants
  name     = "tenant-${each.key}"
  policy   = <<-EOT
    # vault-agent renews its own token
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # Issue ONLY this VM's internal-TLS cert (rule defined in pki.tf)
    ${local.pki_tenant_internal_rules}

    # Read ONLY this tenant's own KV secrets (kv-v2: data + metadata)
    path "secret/data/${each.value.kv_prefix}/*" {
      capabilities = ["read"]
    }
    path "secret/metadata/${each.value.kv_prefix}/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "tenant" {
  for_each       = var.tenants
  backend        = vault_auth_backend.approle.path
  role_name      = "tenant-${each.key}"
  token_policies = [vault_policy.tenant[each.key].name]
  token_ttl      = 3600
  token_max_ttl  = 86400
}
