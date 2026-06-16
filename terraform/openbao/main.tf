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

# ── Policies ───────────────────────────────────────────────────────────────────

locals {
  # Secrets the terraform/authentik target GENERATES and writes back into OpenBao
  # (OIDC client_id/secret per app, plus the roster db/session/ldap passwords).
  # krg-deploy runs that target via deploy/deploy-tofu.sh, so its AppRole needs to
  # manage exactly these paths. Enumerated on purpose — NOT secret/data/krg-prod/*
  # — so the deploy runner can write the OIDC entries without gaining write on every
  # production secret (#187, least-privilege). MUST stay in sync with the
  # vault_kv_secret_v2 resources in terraform/authentik/{vault,roster,guacamole}_secrets.tf:
  # add a path here when a new app's secret is added there, or its apply 403s.
  authentik_managed_secrets = [
    "krg-prod/grafana-oidc",
    "krg-prod/outline-oidc",
    "krg-prod/mlflow-oidc",
    "krg-prod/roster-oidc",
    "krg-prod/roster",
    "krg-prod/roster-ldap",
    "krg-prod/vaultwarden-oidc",
    "krg-prod/guacamole-oidc",
    "krg-prod/guacamole",
    "krg-prod/temporal-oidc",
    "krg-prod/temporal",
    "e4e-nas/garage-ui-oidc",
    "e4e-nas/dsm-sso-oidc",
  ]

  # Render the per-path rules as one string to interpolate into the policy heredoc
  # below (a single ${...} substitution — avoids %{for} directives fighting the
  # <<- heredoc dedent). Full lifecycle on the data path (create/update on apply,
  # read on refresh, delete on destroy) + metadata delete so the resource can be
  # fully removed. Vault's HCL ignores the flat indentation of the rendered block.
  authentik_secret_rules = join("\n", flatten([
    for p in local.authentik_managed_secrets : [
      "path \"secret/data/${p}\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }",
      "path \"secret/metadata/${p}\" { capabilities = [\"read\", \"delete\"] }",
    ]
  ]))
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

    # Read the Grafana ADMIN password the terraform/grafana target consumes:
    # providers.tf reads grafana-admin → provider auth. Scoped to this one path,
    # NOT all of secret/krg-prod/* — the deploy runner shouldn't be able to read
    # every production secret (#187, least-privilege). grafana-oidc (the OTHER
    # value grafana's sso.tf reads) is produced+managed by the authentik target,
    # so it's covered by the authentik_managed_secrets block below (read included).
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
    # client secrets + the roster passwords and stores them here; grafana then
    # reads grafana-oidc from the same set. Paths are enumerated (least-privilege)
    # and rendered from local.authentik_managed_secrets — see that comment for the
    # sync rule.
    ${local.authentik_secret_rules}

    # Generate secret_ids for other roles so OpenTofu can bootstrap them
    path "auth/approle/role/+/secret-id" {
      capabilities = ["create", "update"]
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
  EOT
}

# ── Outputs ────────────────────────────────────────────────────────────────────
# role_ids are non-secret and safe to output. secret_ids are generated
# separately (vault_approle_auth_backend_role_secret_id) and handled outside
# of state to avoid storing them in plaintext.
