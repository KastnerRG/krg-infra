output "krg_deploy_role_id" {
  description = "AppRole role_id for krg-deploy (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.krg_deploy.role_id
}

output "krg_prod_role_id" {
  description = "AppRole role_id for krg-prod (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.krg_prod.role_id
}

output "waiter_role_id" {
  description = "AppRole role_id for waiter (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.waiter.role_id
}

output "kastner_ml_role_id" {
  description = "AppRole role_id for kastner-ml (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.kastner_ml.role_id
}

# Intermediate CA cert (PEM) — the trust anchor consumers verify mTLS peers
# against. A public certificate, NOT a secret. Also fetchable unauthenticated at
# ${vault_addr}/v1/pki_int/ca/pem; surfaced here for convenience.
output "pki_int_ca_cert" {
  description = "Lab-internal intermediate CA certificate (PEM, non-secret)"
  value       = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}
