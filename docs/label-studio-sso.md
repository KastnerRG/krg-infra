# Label Studio Enterprise SSO — PARKED (not integrated)

**Status: parked 2026-06-20. Label Studio is NOT SSO-integrated.** The Authentik
SAML provider/application and its app icon were removed (the integration that drove
them was backed out). This doc is kept as the diagnosis so the next attempt starts
from where we stopped, not from zero. **Tracking issue: #326.**

Label Studio Enterprise is the hosted HumanSignal / Heartex SaaS at
`app.heartex.com` — only the IdP half (a SAML provider on `auth.krg.ucsd.edu`) ever
lived in this repo; the SP half is configured in Label Studio's own org UI.

## Why it's parked

We built the full SAML integration and got the IdP side working end-to-end, but
**Label Studio's ACS returns HTTP 500 on an assertion we proved is valid**, and we
could not see their server-side error. That's a Label-Studio-side failure we can't
diagnose or fix without HumanSignal support's logs (fileable by an org admin — it
goes to the vendor, not the org owner) or org-owner involvement. Rather than leave a
half-working SSO app/tile in Authentik, the integration was removed until someone can
pull those logs.

## What was proven working (IdP side is correct)

- Authentik authenticates the user, signs the assertion (RSA-SHA256), and POSTs it.
- The decoded assertion is valid: `Destination` and `Audience` match the SP's ACS,
  `Issuer` matches the IdP metadata `entityID`, and all four attributes
  (`Email`, `FirstName`, `LastName`, `Groups`) are present and correctly named —
  Label Studio's attribute-mapping screen showed all four **Mapped ✓**.
- `auth.krg.ucsd.edu` and its metadata are publicly reachable (verified from two
  non-UCSD vantages), so it's **not** a firewall/reachability problem.

## What was ruled out as the cause of the 500

- **Email domain / ownership** — we did NOT claim the shared `ucsd.edu` domain (the
  lab doesn't own it; claiming it on the multi-tenant SaaS would capture SSO routing
  for all of UCSD). A lab-owned subdomain (`krg.ucsd.edu`) satisfied the wizard's
  "verify a domain" gate instead.
- **Metadata loading** — the slug metadata URL (`…/application/saml/label-studio/metadata/`)
  302-redirects and heartex's loader won't follow it. Use the **direct** URL
  (`…/api/v3/providers/saml/<pk>/metadata/?download`) or upload the XML file.
- **ACS/audience mismatch** — heartex regenerates the per-org ACS token whenever the
  SSO connection is re-created; the provider's `acs_url`/`audience` must track the
  current value. (A stale token 404s; a URL typo also 404'd during testing.)
- **Issuer mismatch** — assertion `Issuer` matched the metadata `entityID`.
- **The `Groups` list** — the user was in 17 AD groups; trimming the `Groups`
  attribute to one group did **not** clear the 500.
- **Org-owner self-SSO** — the tester is an org admin, not the owner, so this isn't
  the founding-account-self-link case.

## The two remaining unknowns (both inside Label Studio)

- **IdP-initiated is likely unsupported.** Authentik's IdP-initiated URL
  (`…/sso/binding/init/`) POSTs an *unsolicited* assertion (no `InResponseTo`);
  Label Studio 500s on it, which many SaaS SPs do by design.
- **SP-initiated dies before producing an assertion.** Starting from
  `app.heartex.com` → "Log in with SSO" → company domain `krg.ucsd.edu` failed
  before ever reaching Authentik on the last attempts — a heartex-side step we can't
  see into.

Two oddities for support to check against their 500 logs: the assertion's
`AuthnInstant` was ~2 days stale (Authentik reused an old session), and
`AuthnContextClassRef` was `MobileOneFactorContract`.

## How to resume

1. Get HumanSignal support to read the ACS 500's stack trace (note the failure
   timestamp; offer them the full base64 `SAMLResponse`). That ends the guessing.
2. Re-add the IdP side: restore `terraform/authentik/label_studio.tf` (a SAML
   provider + application + the `Email`/`FirstName`/`LastName`/`Groups` attribute
   mappings) from this PR's revert, set `acs_url`/`audience` to the **current** ACS
   token, add the app icon back, and `tofu apply`.
3. Consider trimming the `Groups` mapping to Label-Studio-relevant groups only
   (`startswith("Label Studio")`) regardless — don't over-share the full AD
   directory with a third-party SaaS.
4. Confirm with support whether the SP-initiated flow (company domain
   `krg.ucsd.edu`) is the supported entry point, since IdP-initiated appears not to
   be.

## Related, intentionally left in place

- The **`Label Studio Admins`** AD group (`spec/krg-ad/groups.yml`) is kept — it
  already exists in the live directory and is the role gate for whenever SSO is
  revisited. (Removing it from the spec would only create drift; the apply never
  deletes groups anyway.)
- Label Studio's e4e-nas storage (`spec/e4e-nas/`: the `label_studio` share and its
  Hyper Backup job) is unrelated to SSO and untouched.
