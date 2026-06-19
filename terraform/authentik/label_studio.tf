# Label Studio Enterprise (HumanSignal / Heartex SaaS at app.heartex.com).
#
# Unlike the other KRG apps this one is NOT self-hosted on krg-prod — it's a
# hosted SaaS org. So only the IdP half lives here (this SAML provider +
# application on auth.krg.ucsd.edu). The SP half (uploading our metadata, the
# attribute preset, group→role mapping) is configured in Label Studio's own UI
# under Organization → SSO & SAML and is genuinely external to this repo (like
# the DNS CNAMEs) — see docs/label-studio-sso.md for that runbook.
#
# SAML (not OIDC) on purpose: it's Label Studio Enterprise's documented,
# best-trodden SSO path and needs no client secret stored on our side. The
# assertion is signed with our default keypair; Label Studio verifies it against
# the IdP metadata we hand it.

locals {
  # SP endpoints copied from Label Studio (Organization → SSO & SAML). This org
  # reports the SAME URL for the ACS and the Audience/EntityID. Non-secret — these
  # are exchanged in SAML metadata and carry only the org id; see
  # docs/label-studio-sso.md.
  label_studio_acs_url  = "https://app.heartex.com/saml/96b41ce87868c7da174b3593c2555d6231c878916f25d806bff2e3330d5b722c3cefcf4da5ecc2836a424f32e0d460181f9a34d54e8eb59210b86ef04a068f7c/acs"
  label_studio_audience = local.label_studio_acs_url
}

# ── SAML attribute statements ───────────────────────────────────────────────────
# Label Studio's default attribute preset reads these exact PascalCase names:
# Email / FirstName / LastName / Groups (docs.humansignal.com/guide/auth_setup).
# If you pick a different preset in the Label Studio UI, the saml_name values here
# must match it.

# NameID = email. Label Studio keys/creates accounts off the email; emit it as the
# SAML subject (emailAddress format). saml_name is unused when a mapping is the
# NameID source, but the schema still requires it.
resource "authentik_property_mapping_provider_saml" "label_studio_nameid" {
  name       = "Label Studio — NameID (email)"
  saml_name  = "NameID"
  expression = "return request.user.email"
}

resource "authentik_property_mapping_provider_saml" "label_studio_email" {
  name       = "Label Studio — Email"
  saml_name  = "Email"
  expression = "return request.user.email"
}

# Authentik stores one display name (request.user.name); Label Studio wants it
# split into first/last. These only populate the user's display name in Label
# Studio (identity is the email), so a naive whitespace split is fine. If your AD
# sync ever lands givenName/sn into request.user.attributes, prefer those.
resource "authentik_property_mapping_provider_saml" "label_studio_first_name" {
  name       = "Label Studio — FirstName"
  saml_name  = "FirstName"
  expression = <<-EOT
    return request.user.name.split(" ")[0] if request.user.name else ""
  EOT
}

resource "authentik_property_mapping_provider_saml" "label_studio_last_name" {
  name       = "Label Studio — LastName"
  saml_name  = "LastName"
  expression = <<-EOT
    parts = request.user.name.split(" ") if request.user.name else []
    return " ".join(parts[1:]) if len(parts) > 1 else ""
  EOT
}

# Multi-valued: the user's AD group names (same source the OIDC `groups` scope
# uses). In Label Studio, Organization → map these group NAMES to org roles /
# workspaces / projects — the names must match byte-for-byte. See groups.tf for
# why groups are AD-sourced.
resource "authentik_property_mapping_provider_saml" "label_studio_groups" {
  name       = "Label Studio — Groups"
  saml_name  = "Groups"
  expression = "return [group.name for group in request.user.groups.all()]"
}

# ── SAML provider ───────────────────────────────────────────────────────────────

resource "authentik_provider_saml" "label_studio" {
  name               = "Provider for Label Studio Enterprise"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id

  # SP endpoints (see the locals above — this org uses the same URL for both).
  acs_url  = local.label_studio_acs_url
  audience = local.label_studio_audience

  # SaaS SP consumes the assertion over HTTP-POST.
  sp_binding = "post"

  name_id_mapping = authentik_property_mapping_provider_saml.label_studio_nameid.id
  property_mappings = [
    authentik_property_mapping_provider_saml.label_studio_email.id,
    authentik_property_mapping_provider_saml.label_studio_first_name.id,
    authentik_property_mapping_provider_saml.label_studio_last_name.id,
    authentik_property_mapping_provider_saml.label_studio_groups.id,
  ]

  # Sign the assertion with the default self-signed keypair (same one the OIDC
  # providers use as their RS256 key). Label Studio verifies it against the IdP
  # metadata/cert we upload to it.
  signing_kp     = data.authentik_certificate_key_pair.default.id
  sign_assertion = true
  sign_response  = false
}

resource "authentik_application" "label_studio" {
  name = "Label Studio"
  # slug is load-bearing: Authentik's SAML metadata + SSO URLs embed
  # /application/saml/label-studio/ — that metadata URL is what you hand Label
  # Studio in docs/label-studio-sso.md.
  slug              = "label-studio"
  protocol_provider = authentik_provider_saml.label_studio.id
  # Dashboard tile → Label Studio's login, which SP-initiates SSO back to us (the
  # reliable SaaS flow). New tab since it leaves the lab domain.
  meta_launch_url  = "https://app.heartex.com/"
  meta_description = "Data annotation / labeling (Label Studio Enterprise)"
  # No clean off-the-shelf logo in dashboard-icons yet — tracked in the media-icons
  # README "Not yet iconed" list. Add meta_icon = "krg-icons/label-studio.svg" once
  # one lands.
  group           = "KRG Services"
  open_in_new_tab = true
}
