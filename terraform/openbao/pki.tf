# ── PKI: KRG lab-internal certificate authority ──────────────────────────────
#
# A PRIVATE two-tier CA (root → intermediate) for mutual-TLS BETWEEN lab
# services. This is deliberately SEPARATE from the public Let's Encrypt certs
# Traefik issues for browser HTTPS: mTLS client/server certs can't be public-CA
# issued, and these are machine endpoints, not browser ones. Two PKIs, two jobs.
#
# First consumer: the Temporal gRPC frontend on krg-prod. The frontend presents
# a SERVER cert from the `temporal-frontend` role and REQUIRES client auth
# (TEMPORAL_TLS_REQUIRE_CLIENT_AUTH=true), so only holders of a CLIENT cert from
# the `temporal-client` role — the terraform/temporal runner + any worker/UI —
# can reach :7233. See terraform/temporal/ and
# nix/docker-compose/krg-prod/compose.temporal.yml.
#
# Two-tier so the root can stay dormant: the root signs ONLY the intermediate;
# every leaf cert is issued by the intermediate. Rotating leaf-issuing trust
# means replacing the intermediate, never redistributing/regenerating the root.

# ── Root CA ──────────────────────────────────────────────────────────────────
# Long-lived; its only job is to sign the intermediate below.
resource "vault_mount" "pki_root" {
  path                      = "pki"
  type                      = "pki"
  description               = "KRG lab-internal root CA (signs only the intermediate)"
  default_lease_ttl_seconds = 60 * 60 * 24 * 365  # 1y (roots don't issue leaves)
  max_lease_ttl_seconds     = 60 * 60 * 24 * 3650 # 10y
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki_root.path
  type        = "internal" # key is generated and STAYS in OpenBao, never exported
  common_name = var.pki_root_common_name
  ttl         = 60 * 60 * 24 * 3650 # 10y
  key_type    = "ec"
  key_bits    = 256
}

# ── Intermediate CA ───────────────────────────────────────────────────────────
# Issues every leaf cert. Standard CSR → root-sign → set-signed dance.
resource "vault_mount" "pki_int" {
  path                      = "pki_int"
  type                      = "pki"
  description               = "KRG lab-internal intermediate CA (issues leaf certs)"
  default_lease_ttl_seconds = 60 * 60 * 24 * 90   # 90d default leaf TTL
  max_lease_ttl_seconds     = 60 * 60 * 24 * 1825 # 5y (the intermediate cert itself)
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = var.pki_int_common_name
  key_type    = "ec"
  key_bits    = 256
}

resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend     = vault_mount.pki_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name = var.pki_int_common_name
  ttl         = 60 * 60 * 24 * 1825 # 5y
  format      = "pem_bundle"        # bundle includes the issuing chain
}

resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}

# Embed where to fetch the CA + CRL into issued leaf certs (so verifiers can
# build the chain / check revocation without out-of-band config). The /ca and
# /crl endpoints are UNAUTHENTICATED by design, so no policy grant is needed to
# read them — consumers fetch the trust anchor freely; only ISSUING is gated.
resource "vault_pki_secret_backend_config_urls" "int" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.vault_addr}/v1/pki_int/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/pki_int/crl"]
}

# ── Issuing roles ─────────────────────────────────────────────────────────────

# temporal-frontend — the gRPC frontend's SERVER identity. krg-prod's vault-agent
# issues against this, renders cert+key to /run tmpfs, and auto-renews. SANs must
# cover whatever name clients verify (the provider's tls.server_name): the docker
# service name `temporal` internally, plus the public name if it's ever fronted.
resource "vault_pki_secret_backend_role" "temporal_frontend" {
  backend            = vault_mount.pki_int.path
  name               = "temporal-frontend"
  allowed_domains    = var.temporal_frontend_domains
  allow_bare_domains = true # permit CN=="temporal" (a bare service name, no dots)
  allow_subdomains   = false
  allow_localhost    = true
  server_flag        = true
  client_flag        = false
  key_type           = "ec"
  key_bits           = 256
  ttl                = 60 * 60 * 24 * 30 # 30d issued
  max_ttl            = 60 * 60 * 24 * 90 # 90d ceiling
}

# temporal-client — CLIENT certs for callers of the frontend: the
# terraform/temporal provider (run by krg-deploy) and any worker/UI. server_flag
# off so these can't masquerade as the frontend.
resource "vault_pki_secret_backend_role" "temporal_client" {
  backend            = vault_mount.pki_int.path
  name               = "temporal-client"
  allowed_domains    = var.temporal_client_domains
  allow_bare_domains = true
  allow_subdomains   = false
  server_flag        = false
  client_flag        = true
  key_type           = "ec"
  key_bits           = 256
  ttl                = 60 * 60 * 24 * 7  # 7d issued (short — callers re-issue)
  max_ttl            = 60 * 60 * 24 * 30 # 30d ceiling
}

# ── General lab roles (AD-aware) ──────────────────────────────────────────────

# host — SERVER cert for any lab host/service presenting TLS that isn't Temporal:
# waiter's XRDP endpoint, future internal services, etc. The host's vault-agent
# issues + renews to /run tmpfs. SAN is the host's FQDN under the AD DNS zone
# (krg.local) and/or the public zone (krg.ucsd.edu). Because every host trusts the
# CA root fleet-wide (nix profiles/base.nix security.pki), peers validate these
# leaves BY CHAIN — so a leaf rotating on each render no longer trips cert-TOFU
# (the impermanence pain it replaces). Server-only: a host identity can't be
# replayed as a client cert.
resource "vault_pki_secret_backend_role" "host" {
  backend          = vault_mount.pki_int.path
  name             = "host"
  allowed_domains  = var.host_allowed_domains
  allow_subdomains = true # e.g. waiter.krg.local, grafana.krg.ucsd.edu
  server_flag      = true
  client_flag      = false
  key_type         = "ec"
  key_bits         = 256
  ttl              = 60 * 60 * 24 * 30 # 30d issued
  max_ttl          = 60 * 60 * 24 * 90 # 90d ceiling
}

# user — CLIENT cert bound to an AD identity. The AD userPrincipalName goes in an
# otherName SAN (OID 1.3.6.1.4.1.311.20.2.3 — the AD/PKINIT UPN extension), so the
# cert IS the AD principal and downstream mTLS authz keys off AD group membership
# instead of a parallel cert-only namespace. Issued via the AD-group-gated policies
# in ldap.tf: a user logs into OpenBao with their KRG.LOCAL account and mints their
# own short-lived cert. SANs are deliberately PKINIT-ready (if cert-based Kerberos
# logon lands later, no re-issue needed). Client-only + short TTL (re-minted at use).
resource "vault_pki_secret_backend_role" "user" {
  backend            = vault_mount.pki_int.path
  name               = "user"
  allowed_domains    = [var.ad_upn_suffix] # CN/email domain, if used
  allow_bare_domains = true                # CN == bare sAMAccountName
  allow_subdomains   = false
  allowed_other_sans = ["1.3.6.1.4.1.311.20.2.3;UTF8:*@${var.ad_upn_suffix}"]
  server_flag        = false
  client_flag        = true
  key_type           = "ec"
  key_bits           = 256
  ttl                = 60 * 60 * 24 * 1 # 1d issued (short — re-minted at login)
  max_ttl            = 60 * 60 * 24 * 7 # 7d ceiling
}

# ── Policy grants folded into the krg-deploy / krg-prod policies (main.tf) ─────
# Kept here so all PKI specifics live in one file; interpolated via
# ${local.pki_*_rules} into the heredocs in main.tf (same module, same pattern
# as local.authentik_secret_rules). Reading the CA chain needs NO grant (public
# endpoints, see config_urls above) — only certificate ISSUANCE is privileged.
locals {
  # krg-deploy (terraform/temporal runner): mint CLIENT certs to authenticate to
  # the frontend. It applies config; it does not run the server.
  pki_krg_deploy_rules = <<-EOT
    # Issue Temporal mTLS CLIENT certs (terraform/temporal provider auth) — see pki.tf
    path "pki_int/issue/temporal-client" {
      capabilities = ["create", "update"]
    }
  EOT

  # krg-prod (vault-agent on the host): mint BOTH the frontend SERVER cert the
  # temporal container presents AND a CLIENT cert for temporal-ui — the UI is a
  # client of the mTLS frontend, so it needs its own cert. Both rendered to /run
  # tmpfs by the agent (see nix/hosts/krg-prod/default.nix krg.vaultAgent).
  pki_krg_prod_rules = <<-EOT
    # Issue the Temporal frontend SERVER cert (vault-agent renders it) — see pki.tf
    path "pki_int/issue/temporal-frontend" {
      capabilities = ["create", "update"]
    }

    # Issue the temporal-ui CLIENT cert (the UI authenticates to the frontend)
    path "pki_int/issue/temporal-client" {
      capabilities = ["create", "update"]
    }
  EOT
}
