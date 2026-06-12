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

    # Read the Grafana secrets the terraform/grafana target consumes. krg-deploy
    # runs that target via deploy/deploy-tofu.sh (AppRole login): providers.tf
    # reads grafana-admin (admin password → provider auth) and sso.tf reads
    # grafana-oidc (client_id/secret). Scoped to these two paths, NOT all of
    # secret/krg-prod/* — the deploy runner shouldn't be able to read every
    # production secret (#187). The authentik WRITE-back side of #187 stays
    # deferred (bigger blast radius / needs a design decision). NOTE: grafana-oidc
    # is produced by the authentik target, so grafana fully applies only once
    # that's seeded.
    path "secret/data/krg-prod/grafana-admin" {
      capabilities = ["read"]
    }
    path "secret/data/krg-prod/grafana-oidc" {
      capabilities = ["read"]
    }

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
