variable "vault_addr" {
  description = "OpenBao API address"
  type        = string
  default     = "https://krg-vault.ucsd.edu:8200"
}

# ── PKI (lab-internal CA, see pki.tf) ────────────────────────────────────────

variable "pki_root_common_name" {
  description = "Subject CN of the lab-internal ROOT CA"
  type        = string
  default     = "KRG Lab Internal Root CA"
}

variable "pki_int_common_name" {
  description = "Subject CN of the lab-internal INTERMEDIATE CA (issues leaf certs)"
  type        = string
  default     = "KRG Lab Internal Intermediate CA"
}

variable "temporal_frontend_domains" {
  description = <<-EOT
    Names the temporal-frontend SERVER cert may carry. Must include whatever
    clients verify as the TLS server name: the docker service name `temporal`
    (the UI, internally) AND the public name external workers + the tofu provider
    connect to (`workflows.krg.ucsd.edu` — the gRPC frontend is published to the
    internet on :7233, mTLS-gated).
  EOT
  type        = list(string)
  default     = ["temporal", "temporal.krg.ucsd.edu", "workflows.krg.ucsd.edu"]
}

variable "temporal_client_domains" {
  description = <<-EOT
    Identity names the temporal-client CLIENT certs may carry (cert CN/SAN).
    The frontend only checks the cert is CA-signed, but scoping the issuable
    names keeps the role least-privilege.
  EOT
  type        = list(string)
  default     = ["krg-deploy", "temporal-worker", "temporal-ui"]
}

variable "incus_client_domains" {
  description = <<-EOT
    Identity names the incus-client CLIENT certs may carry (cert CN). krg-deploy's
    terraform/incus provider mints one to authenticate to the krg-nat Incus API.
    krg-nat only checks the cert chains to the fleet CA; scoping the issuable names
    keeps the role least-privilege.
  EOT
  type        = list(string)
  default     = ["krg-deploy"]
}

variable "host_allowed_domains" {
  description = <<-EOT
    Domains the general-purpose `host` SERVER role (pki.tf) may issue under, with
    subdomains allowed. Covers the AD DNS zone and the public lab zone so a host
    can present a cert for either name a peer might verify.
  EOT
  type        = list(string)
  default     = ["krg.local", "krg.ucsd.edu"]
}

variable "ad_upn_suffix" {
  description = <<-EOT
    The AD userPrincipalName suffix (DNS form, lowercase) stamped into the `user`
    client cert's UPN otherName SAN, e.g. alice@krg.local. Match the actual UPN
    suffix configured in KRG.LOCAL.
  EOT
  type        = string
  default     = "krg.local"
}

# ── AD (LDAP) auth — see ldap.tf ─────────────────────────────────────────────
# binddn / bindpass / ldap_ca_cert have NO defaults on purpose: they're
# environment-specific and (bindpass) secret, so apply must supply them
# (TF_VAR_ldap_bindpass) or fail loudly rather than bind as the wrong principal.

variable "ldap_url" {
  description = "DC LDAPS URL. ldaps:// (port 636) so the bind is encrypted+verified."
  type        = string
  default     = "ldaps://krg-ldap.krg.local"
}

variable "ldap_binddn" {
  description = "DN of the dedicated read-only OpenBao service account in KRG.LOCAL."
  type        = string
}

variable "ldap_bindpass" {
  description = "Password for ldap_binddn. Supply via TF_VAR_ldap_bindpass — never a tfvars file."
  type        = string
  sensitive   = true
}

variable "ldap_ca_cert" {
  description = <<-EOT
    PEM of the CA that signs the DC's LDAPS certificate, so OpenBao verifies the
    DC. At bootstrap this is Samba's self-signed LDAPS cert; once the DC cert is
    re-issued from pki_int, swap this to the lab root.
  EOT
  type        = string
}

variable "ldap_userdn" {
  description = "Base DN under which to find users."
  type        = string
  default     = "CN=Users,DC=krg,DC=local"
}

variable "ldap_groupdn" {
  description = "Base DN under which to find groups."
  type        = string
  default     = "DC=krg,DC=local"
}

variable "ldap_upndomain" {
  description = "UPN domain so `user@krg.local` binds resolve."
  type        = string
  default     = "krg.local"
}

variable "ldap_groupfilter" {
  description = <<-EOT
    Group-membership filter. Uses AD's LDAP_MATCHING_RULE_IN_CHAIN
    (1.2.840.113556.1.4.1941) so NESTED group membership resolves — a user in a
    group nested under a mapped group still inherits the policy.
  EOT
  type        = string
  default     = "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:={{.UserDN}}))"
}

variable "pki_ad_group_roles" {
  description = <<-EOT
    AD group → the pki_int issuing roles its members may mint BY HAND after
    `bao login -method=ldap`. This is the HUMAN issuance path; machines issue via
    AppRole (main.tf) and never consult these groups. ldap.tf turns each entry into
    a least-privilege policy + group binding. Group names must exist in KRG.LOCAL
    (see docs/pki-ad-integration.md "Human cert issuance"). Widen as needs grow —
    e.g. "ARM-PDK" = ["user"].
  EOT
  type        = map(list(string))
  default = {
    # Admins can mint any lab cert by hand (bring-up, debugging, break-glass).
    "Domain Admins" = ["host", "user", "temporal-client"]

    # Temporal users mint their own AD-identity client cert (`user`) to reach the
    # mTLS frontend interactively (CLI/SDK from a workstation). Long-running workers
    # are MACHINES — they get a `temporal-client` cert via AppRole/vault-agent, not
    # this path. RENAME to the real KRG.LOCAL group once AD groups are finalized
    # (the binding matches no one until that group exists).
    "Temporal Users" = ["user"]
  }
}

variable "tenants" {
  description = <<-EOT
    The e4e-prod student-project tenants (mirrors the Nix krg.tenants roster). Each
    gets an AppRole `tenant-<name>` + a least-privilege policy: mint its own
    `tenant-internal` cert and read its own KV path. `kv_prefix` is the path under the
    `secret` kv-v2 mount, matching the Nix `secrets.openbaoPath` minus the `secret/`
    prefix (e.g. "e4e-student/fishsense"). Default empty — populated as tenants land.
  EOT
  type = map(object({
    kv_prefix = string
  }))
  default = {}
}
