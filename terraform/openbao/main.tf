# OpenBao configuration for krg-vault.
# Applied from krg-deploy after `bao operator init` + unseal.

# ── Secret engines ─────────────────────────────────────────────────────────────

# KV v2 — primary store for all KRG secrets.
resource "vault_mount" "kv" {
  path    = "secret"
  type    = "kv"
  options = { version = "2" }
}

# ── Auth methods ───────────────────────────────────────────────────────────────

# AppRole — machine-to-machine auth (no static tokens).
# Each system gets a role_id (non-secret) + secret_id (secret) pair.
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

# ── Roles ──────────────────────────────────────────────────────────────────────

# krg-deploy: OpenTofu runner. Needs to read its own secrets and manage
# secret_ids for other roles (so it can bootstrap them on first deploy).
resource "vault_approle_auth_backend_role" "krg_deploy" {
  backend        = vault_auth_backend.approle.path
  role_name      = "krg-deploy"
  token_policies = [vault_policy.krg_deploy.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
}

# krg-prod: lab-wide production stack. vault-agent on the host authenticates
# with this role and writes secrets into .secrets/ so Docker Compose can use
# them. See the "Automate secrets" TODO in nix/hosts/krg-prod/default.nix.
resource "vault_approle_auth_backend_role" "krg_prod" {
  backend        = vault_auth_backend.approle.path
  role_name      = "krg-prod"
  token_policies = [vault_policy.krg_prod.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
}

# XRDP compute hosts (waiter, kastner-ml): each box's vault-agent authenticates with
# its own role to issue the `host` SERVER cert xrdp presents for RDP TLS (pki.tf). No
# KV access — a box only mints its own short-lived cert. Per-host roles (not one shared)
# so a compromised box can't impersonate another.
resource "vault_approle_auth_backend_role" "waiter" {
  backend        = vault_auth_backend.approle.path
  role_name      = "waiter"
  token_policies = [vault_policy.waiter.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
}

resource "vault_approle_auth_backend_role" "kastner_ml" {
  backend        = vault_auth_backend.approle.path
  role_name      = "kastner-ml"
  token_policies = [vault_policy.kastner_ml.name]
  token_ttl      = 3600
  token_max_ttl  = 86400
}

# (No krg-nat AppRole: Incus OIDC is a PUBLIC client with no client secret — verified
# on-box — so krg-nat needs no vault-agent render and thus no KV access. The role +
# policy added in the initial OIDC PR were removed once that was found.)

# ── Policies ───────────────────────────────────────────────────────────────────

locals {
  # Secrets the terraform/authentik target GENERATES and writes back into OpenBao
  # (OIDC client_id/secret per app, plus roster/guacamole/temporal/proxmox-ldap-bind
  # passwords). krg-deploy runs that target via deploy/deploy-tofu.sh, so its AppRole
  # needs write on exactly these paths — but NOT secret/data/krg-prod/* (the deploy
  # runner must not be able to write every production secret; #187, least-privilege).
  #
  # The krg-prod generated secrets all live under the GLOBBABLE sub-path
  # secret/krg-prod/authentik-managed/<name> (authentik_managed_glob_prefixes below),
  # so the policy is one wildcard rather than a per-path enumeration: adding a new
  # app's secret there needs NO terraform/openbao apply. Only e4e-nas's two generated
  # secrets stay enumerated here — they're stable, and their flat paths are referenced
  # across the synology effort's docs. Sync rule: you only edit THIS list for a new
  # e4e-nas secret (or a brand-new prefix); krg-prod additions under authentik-managed/
  # are covered by the glob automatically.
  authentik_managed_secrets = [
    "e4e-nas/garage-ui-oidc",
    "e4e-nas/dsm-sso-oidc",
    # (The transitional pre-migration FLAT krg-prod paths are gone: #323 moved every
    # krg-prod generated secret to krg-prod/authentik-managed/<name> — now covered by
    # the glob below — and the old flat paths were destroyed in that apply. This list
    # is back to just the two e4e-nas secrets that stay enumerated.)
  ]

  # Globbable sub-paths the authentik target writes its GENERATED secrets under. Each
  # becomes `secret/{data,metadata}/<prefix>/*`. OpenBao ACL paths take a trailing `*`
  # (matches the rest of the path) and `+` (matches ONE path segment, anywhere) — so a
  # dedicated subtree is how we get a wildcard without broadening to all of krg-prod/*,
  # and `+` lets one rule span a variable segment (e.g. the tenant name). New secrets
  # written under any prefix here need NO terraform/openbao apply — that's the point.
  authentik_managed_glob_prefixes = [
    "krg-prod/authentik-managed",
    # Per-tenant OIDC secrets Authentik generates for an e4e tenant, written UNDER the
    # tenant's own KV (secret/tenants/<name>/oidc/*) so the tenant's vault-agent reads
    # them with its existing secret/data/tenants/<name>/* grant. SCOPED to .../oidc so
    # the authentik writer can't touch the tenant's own app secrets (postgres, etc.).
    #
    # `+` matches the tenant-name segment, so this ONE rule covers EVERY tenant
    # (fishsense, smartfin, roster, …) — adding a tenant needs NO terraform/openbao
    # apply, the same self-service the krg-prod/authentik-managed glob already gives new
    # apps. (Was pinned to `tenants/fishsense/oidc`; a per-tenant entry meant every new
    # tenant tripped the privileged openbao apply — the #438 deploy 403. Templating it
    # ends that class of manual apply.)
    "tenants/+/oidc",
  ]

  # Render the per-path rules as one string to interpolate into the policy heredoc
  # below (a single ${...} substitution — avoids %{for} directives fighting the
  # <<- heredoc dedent). Full lifecycle on BOTH the data and metadata paths
  # (create/update on apply, read on refresh, delete on destroy). The metadata path
  # needs create/update — NOT just read/delete — because the hashicorp/vault v5
  # provider's vault_kv_secret_v2 manages custom_metadata, writing it with a
  # `PUT secret/metadata/<p>` on every create/update (older OIDC secrets predate v5,
  # so they never hit this). Vault's HCL ignores the flat indentation of the block.
  authentik_secret_rules = join("\n", flatten(concat(
    [
      for p in local.authentik_managed_secrets : [
        "path \"secret/data/${p}\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }",
        "path \"secret/metadata/${p}\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }",
      ]
    ],
    [
      for p in local.authentik_managed_glob_prefixes : [
        "path \"secret/data/${p}/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }",
        "path \"secret/metadata/${p}/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }",
      ]
    ]
  )))
}

resource "vault_policy" "krg_deploy" {
  name   = "krg-deploy"
  policy = <<-EOT
    # Read krg-deploy's own secrets
    path "secret/data/krg-deploy/*" {
      capabilities = ["read"]
    }

    # Read e4e-nas (Synology) secrets. krg-deploy is the control node that runs
    # the synology_* ansible roles against e4e-nas; DSM has no vault-agent (the
    # synology subtree is intentionally zero-prereq), so deploy/deploy-ansible.sh
    # AppRole-logs in here and materializes the NAS secrets as ansible extra_vars
    # at apply time. Covers garage (rpc/admin/metrics tokens), garage-ui-oidc, and
    # the other NAS secrets as #110/#75 seed them. Read-only — krg-deploy applies
    # config, it does not generate these.
    path "secret/data/e4e-nas/*" {
      capabilities = ["read"]
    }

    # WRITE the per-key Garage access credentials. Unlike the rest of e4e-nas/*
    # (read-only above), krg-deploy CREATE-ONCE-provisions each Garage access key's
    # {access_key_id, secret_access_key} here (deploy/deploy-ansible.sh) so a lost
    # NAS keys_dir is recoverable and OpenBao (not the box) is the durable source of
    # truth (#75; apply_garage.py then ImportKeys from it). Scoped to just this
    # subpath (least-privilege): the rest of e4e-nas stays read-only; read is already
    # granted by the e4e-nas/* rule above. NEW capability -> needs a privileged
    # openbao apply before the first consuming deploy, else the put 403s.
    path "secret/data/e4e-nas/garage-keys/*" {
      capabilities = ["create", "update"]
    }

    # Read the Grafana ADMIN password the terraform/grafana target consumes:
    # providers.tf reads grafana-admin → provider auth. Scoped to this one path,
    # NOT all of secret/krg-prod/* — the deploy runner shouldn't be able to read
    # every production secret (#187, least-privilege). grafana-oidc (the OTHER
    # value grafana's sso.tf reads) is produced+managed by the authentik target, so
    # it's covered by the authentik-managed write-back glob below (read included).
    path "secret/data/krg-prod/grafana-admin" {
      capabilities = ["read"]
    }

    # Read the authentik LDAP-source bind password (TF_VAR_ldap_bind_password for
    # the terraform/authentik target). It lives under krg-prod (an authentik-service
    # secret, also consumed by the LDAP outpost on krg-prod), so it needs an explicit
    # scoped read here — secret/krg-prod/* is NOT blanket-readable (#187).
    path "secret/data/krg-prod/authentik-ldap" {
      capabilities = ["read"]
    }

    # Write-back for the terraform/authentik target (#187). authentik mints OIDC
    # client secrets + the roster/guacamole/temporal/proxmox-ldap-bind passwords and
    # stores them here; grafana then reads grafana-oidc from the same set. The krg-prod
    # generated secrets are covered by a single glob (secret/krg-prod/authentik-managed/*),
    # so new apps need no openbao apply; e4e-nas's two stay enumerated. Both are
    # rendered from the locals above (least-privilege — NOT secret/data/krg-prod/*).
    ${local.authentik_secret_rules}

    # PKI: issue Temporal mTLS client certs (rules defined in pki.tf)
    ${local.pki_krg_deploy_rules}

    # Generate secret_ids for other roles so OpenTofu can bootstrap them
    path "auth/approle/role/+/secret-id" {
      capabilities = ["create", "update"]
    }

    # Read role_ids (non-secret) so deploy-nixos.sh can stage a vault-agent host's
    # secret-zero (role-id + a freshly-minted secret-id) before the switch — see
    # deploy/deploy-nixos.sh stage_vault_secret_zero + nix krg.vaultAgent.
    path "auth/approle/role/+/role-id" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "krg_prod" {
  name   = "krg-prod"
  policy = <<-EOT
    # Read all krg-prod secrets (Authentik, Grafana, Outline, MLflow, etc.)
    path "secret/data/krg-prod/*" {
      capabilities = ["read"]
    }

    # Allow vault-agent to renew its own token
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # PKI: issue the Temporal frontend server cert (rules defined in pki.tf)
    ${local.pki_krg_prod_rules}
  EOT
}

resource "vault_policy" "waiter" {
  name   = "waiter"
  policy = <<-EOT
    # Allow vault-agent to renew its own token
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # PKI: issue waiter's host server cert for XRDP TLS (rules defined in pki.tf)
    ${local.pki_xrdp_host_rules}
  EOT
}

resource "vault_policy" "kastner_ml" {
  name   = "kastner-ml"
  policy = <<-EOT
    # Allow vault-agent to renew its own token
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # PKI: issue kastner-ml's host server cert for XRDP TLS (rules defined in pki.tf)
    ${local.pki_xrdp_host_rules}
  EOT
}

# ── Outputs ────────────────────────────────────────────────────────────────────
# role_ids are non-secret and safe to output. secret_ids are generated
# separately (vault_approle_auth_backend_role_secret_id) and handled outside
# of state to avoid storing them in plaintext.
