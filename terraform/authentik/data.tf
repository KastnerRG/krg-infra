# Default flows — present in every fresh Authentik install, referenced by slug.
# Using data sources avoids re-creating flows that Authentik manages itself.

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# ── OIDC scope mappings ────────────────────────────────────────────────────────

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

# NOTE: the `groups` scope mapping is CREATED as a resource (not looked up) in
# applications_e4e.tf — stock Authentik ships no managed `scope-groups`, so a
# data lookup 400s ("not one of the available choices"). See the resource there.

# Default self-signed cert, used as the OAuth2 providers' RS256 signing key so
# ID tokens are verifiable via jwks_uri (garage_ui needs this — without a signing
# key Authentik falls back to HS256 + empty JWKS). Ships with every Authentik
# install under this exact name.
data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate"
}

# ── LDAP source property mappings ─────────────────────────────────────────────
# Matches the 7 user + 1 group mappings selected in the live LDAP source config.

# Base LDAP mappings
data "authentik_property_mapping_source_ldap" "dn_user_path" {
  managed = "goauthentik.io/sources/ldap/default-dn-path"
}

data "authentik_property_mapping_source_ldap" "mail" {
  managed = "goauthentik.io/sources/ldap/default-mail"
}

data "authentik_property_mapping_source_ldap" "name" {
  managed = "goauthentik.io/sources/ldap/default-name"
}

# Active Directory-specific mappings
data "authentik_property_mapping_source_ldap" "ad_given_name" {
  managed = "goauthentik.io/sources/ldap/ms-givenName"
}

data "authentik_property_mapping_source_ldap" "ad_sam_account_name" {
  managed = "goauthentik.io/sources/ldap/ms-samaccountname"
}

data "authentik_property_mapping_source_ldap" "ad_sn" {
  managed = "goauthentik.io/sources/ldap/ms-sn"
}

data "authentik_property_mapping_source_ldap" "ad_upn" {
  managed = "goauthentik.io/sources/ldap/ms-userprincipalname"
}

# ── SAML provider property mappings (Fleet — ADR 0012) ────────────────────────
# Fleet's console SSO is SAML 2.0 ONLY (no OIDC), so it's the repo's first
# authentik_provider_saml. Default managed SAML mappings, looked up by their managed
# identifier (same approach as the OIDC scope/LDAP data sources above).
data "authentik_property_mapping_provider_saml" "email" {
  managed = "goauthentik.io/providers/saml/email"
}

data "authentik_property_mapping_provider_saml" "username" {
  managed = "goauthentik.io/providers/saml/username"
}

data "authentik_property_mapping_provider_saml" "name" {
  managed = "goauthentik.io/providers/saml/name"
}
