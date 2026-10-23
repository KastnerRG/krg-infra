# Generation moved to terraform/secrets, before the fail-closed host Agent runs.
# Forget old state ownership WITHOUT deleting live secrets. Adopt existing random
# values into the secrets workspace first; see docs/roster-openbao.md.

removed {
  from = random_password.roster_db
  lifecycle {
    destroy = false
  }
}

removed {
  from = random_password.roster_session
  lifecycle {
    destroy = false
  }
}

removed {
  from = random_password.roster_ldap
  lifecycle {
    destroy = false
  }
}

removed {
  from = vault_kv_secret_v2.roster
  lifecycle {
    destroy = false
  }
}

removed {
  from = vault_kv_secret_v2.roster_ldap
  lifecycle {
    destroy = false
  }
}
