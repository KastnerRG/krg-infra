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
# best-trodden SSO path and needs no client secret stored on our side.
#
# RE-ATTEMPT (2026-07-08): this integration was previously built, verified
# correct on the IdP side, and PARKED after Label Studio's ACS returned HTTP 500
# on a valid assertion (see docs/label-studio-sso.md history). Re-adding with a
# freshly-issued ACS/Audience URL (heartex regenerates this token whenever the
# SSO connection is re-created, so the old one is dead) — if the 500 recurs,
# park again rather than leave a broken tile live.

locals {
  # SP endpoints copied from Label Studio (Organization → SSO & SAML). This org
  # reports the SAME URL for the ACS and the Audience/EntityID. Non-secret — these
  # are exchanged in SAML metadata and carry only the org id; see
  # docs/label-studio-sso.md. Re-copy here if the SSO connection is ever
  # recreated on the Label Studio side (it rotates this token).
  label_studio_acs_url  = "https://app.heartex.com/saml/db9c7ce021d82b5b6af146e98237efcdfc3b3d31120f4eb0544da35afb514578e55388e10de3eb848c6439f2276448d3b7940764da15497d7216b288d2e548c3/acs"
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

# Multi-valued: AD group names, TRIMMED to Label-Studio-relevant groups only
# (names starting with "Label Studio", e.g. "Label Studio Admins" — spec/krg-ad/groups.yml).
# The prior attempt sent the full AD group list; don't over-share the whole
# directory structure with a third-party SaaS. In Label Studio, Organization →
# map these group NAMES to org roles / workspaces / projects — names must match
# byte-for-byte.
resource "authentik_property_mapping_provider_saml" "label_studio_groups" {
  name       = "Label Studio — Groups"
  saml_name  = "Groups"
  expression = <<-EOT
    return [group.name for group in request.user.groups.all() if group.name.startswith("Label Studio")]
  EOT
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
  # Dashboard tile → Authentik's IdP-initiated SSO endpoint, which POSTs an
  # unsolicited assertion straight to Label Studio's ACS. Clicking the tile logs
  # you in; it does NOT dump you on app.heartex.com's login page to re-enter the
  # company domain. New tab since the flow ends off the lab domain.
  #
  # This is the flow the earlier attempt tried and abandoned: the ACS 500'd on the
  # unsolicited assertion, and IdP-initiated was blamed. That verdict is suspect —
  # the metadata URL Label Studio was pointed at 302-redirected and its loader
  # never followed it (fixed 2026-07-09), so it had no IdP signing cert to verify
  # ANY assertion against. Retry it here; if the 500 returns, the next knob is
  # sign_response (many SPs require the Response, not just the Assertion, signed
  # on an unsolicited POST), then default_relay_state on the provider.
  meta_launch_url  = "${var.authentik_url}/application/saml/label-studio/init/"
  meta_description = "Data annotation / labeling (Label Studio Enterprise)"
  meta_icon        = "krg-icons/label-studio.svg"
  group            = "KRG Services"
  open_in_new_tab  = true
}
