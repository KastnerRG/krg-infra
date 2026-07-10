# Label Studio Enterprise SSO (Authentik SAML)

Single sign-on for our **hosted** Label Studio Enterprise org (HumanSignal /
Heartex SaaS at `app.heartex.com`) via Authentik, so labelers log in with their
KRG.LOCAL AD account instead of a Label-Studio-local password.

Unlike the other KRG apps, Label Studio is **not self-hosted on krg-prod** — it's
someone else's SaaS. So the integration splits cleanly in two:

- **IdP side (ours, IaC):** the SAML provider + application on
  `auth.krg.ucsd.edu`, in `terraform/authentik/label_studio.tf`.
- **SP side (Label Studio's UI):** uploading our metadata, choosing the attribute
  preset, and mapping groups → roles. There is **no API / Terraform provider** for
  a Heartex org's SSO config, so this half is a UI runbook — genuinely external to
  this repo, the same category as publishing a DNS CNAME. Capturing the SP values
  (ACS URL / Audience) is *discovery*; clicking through the wizard to enter our
  metadata is the only IaC-strict-exempt step here because the SP isn't a machine
  we manage.

SAML (not OIDC) on purpose: it's Label Studio Enterprise's documented, best-trodden
SSO path and stores no client secret on our side.

## Status: re-attempt in progress (2026-07-08)

**History:** this integration was built once already (issue #326, PR #307). The
IdP side worked end-to-end — Authentik produced a valid, signed assertion with
matching `Destination`/`Audience`/`Issuer` and all four attributes correctly
mapped — but **Label Studio's ACS returned HTTP 500 on it**, a vendor-side failure
we couldn't see into without HumanSignal support's logs. Rather than leave a
broken tile in the user dashboard, it was backed out (`b1b6a9d`, PR #327 / #321).

This re-attempt restores the same IdP config with a **freshly-issued ACS/Audience
URL** (Heartex regenerates this token whenever the org's SSO connection is
re-created, so the old one is dead regardless), and additionally **trims the
`Groups` SAML attribute** to only Label-Studio-relevant AD group names
(`startswith("Label Studio")`) instead of the full AD group list — a hardening
follow-up noted when this was parked, applied now regardless of the 500 outcome.

**If the ACS 500 recurs:** don't debug blind a second time. Get an org admin to
pull HumanSignal support's server-side stack trace for the failing request (have
the failure timestamp + the base64 `SAMLResponse` ready to hand over), then park
again per the checklist at the bottom of this doc rather than leave it half-wired.

## Authentik side (IaC)

`terraform/authentik/label_studio.tf`:
- `authentik_provider_saml.label_studio` — assertion-signed with the default
  self-signed keypair (`data.authentik_certificate_key_pair.default`); HTTP-POST
  binding; `acs_url`/`audience` from `locals.label_studio_acs_url` (inlined).
- Five SAML attribute statements emitting exactly what Label Studio's **default**
  preset reads:

  | SAML `Name` | value (Authentik expression)                                              |
  |-------------|----------------------------------------------------------------------------|
  | NameID      | `request.user.email` (subject)                                            |
  | `Email`     | `request.user.email`                                                      |
  | `FirstName` | first token of `request.user.name`                                        |
  | `LastName`  | rest of `request.user.name`                                              |
  | `Groups`    | `[g.name for g in request.user.groups.all() if g.name.startswith("Label Studio")]` |

- `authentik_application.label_studio` — slug **`label-studio`** (load-bearing: the
  metadata/SSO URLs embed it), dashboard tile → `app.heartex.com`.

The slug fixes the URLs you hand Label Studio:
- **Metadata URL:** `https://auth.krg.ucsd.edu/api/v3/providers/saml/<pk>/metadata/?download`
  (or grab it from the provider page in the Authentik admin UI — *Providers → Provider
  for Label Studio Enterprise → Download metadata / Copy download URL*). Use the
  **direct** URL, not the slug metadata URL (`…/application/saml/label-studio/metadata/`)
  — that one 302-redirects and Heartex's loader won't follow it (learned the hard
  way on the first attempt).
- **SSO (redirect) URL:** `https://auth.krg.ucsd.edu/application/saml/label-studio/sso/binding/redirect/`

### SP endpoints

The org's ACS URL / Audience are **committed inline** in `label_studio.tf`
(`locals.label_studio_acs_url`) — they're non-secret endpoint URLs in the same
class as every other service URL in this layer (they carry only the org id, are
exchanged in SAML metadata, and grant nothing without the IdP signing key). This
org reports the **same URL for both** the ACS and the Audience/EntityID. If you
ever rotate the org, or recreate the SSO connection on the Label Studio side, this
token changes — re-copy it and edit that local (a stale token 404s).

## Bring-up order (chicken-and-egg)

The SP needs our IdP metadata and the IdP needs the SP's ACS URL, so do it in this
order:

1. **Label Studio → copy SP values.** In the org, *Organization → SSO & SAML*. Copy
   the **Assertion Consumer Service (ACS) URL** (and the **Audience/EntityID** —
   Label Studio uses the same URL unless it shows a distinct one). This is read-only
   discovery.
2. **Authentik → apply.** `tofu apply` in `terraform/authentik/` (the ACS URL is
   already committed inline). This mints the provider and its metadata. If the ACS
   URL/Audience you copied differs from the committed `locals.label_studio_acs_url`,
   update that local first.
3. **Label Studio → upload our metadata.** Back in *Organization → SSO & SAML*,
   provide the Authentik **metadata URL** (or paste the XML). Select the **default**
   attribute preset (so it reads `Email` / `FirstName` / `LastName` / `Groups`) — if
   you must pick a different preset, change the `saml_name`s in
   `label_studio.tf` to match and re-apply.
4. **Label Studio → group → role mapping.** Map the AD group **names** emitted in
   `Groups` to Label Studio org roles / workspaces / projects. Only `Label Studio
   Admins` is emitted today (the attribute is trimmed — see above); add more
   `Label Studio *`-prefixed AD groups (`spec/krg-ad/groups.yml`) if finer-grained
   roles are needed. Names must match byte-for-byte.
5. **Test both flows.** SP-initiated, from Label Studio's own **Login URL** /
   "Log in with SSO" (company domain `krg.ucsd.edu`) — **confirmed working
   2026-07-09**, once the metadata URL was switched to the direct one. Then the
   Authentik dashboard tile, which is now **IdP-initiated** (→
   `…/application/saml/label-studio/init/`, an unsolicited assertion POSTed
   straight to the ACS). Confirm a fresh AD user lands with the expected role from
   their group mapping.

   If the tile 500s: the first attempt blamed unsolicited assertions, but it was
   testing against a metadata URL Label Studio could never load (so it had no IdP
   signing cert). Retry order before blaming Heartex — flip `sign_response = true`
   on the provider (many SPs require the Response signed, not just the Assertion,
   on an unsolicited POST), then set `default_relay_state`. Only then is
   "Heartex doesn't support IdP-initiated" a supported conclusion; SP-initiated
   still works regardless, so revert `meta_launch_url` to `https://app.heartex.com/`
   to leave a working tile while you ask support.

## Notes / gotchas

- **First/last name** come from a whitespace split of the single Authentik display
  name (`request.user.name`); they only populate the Label Studio display name —
  identity is the email. If the AD sync ever lands `givenName`/`sn` into
  `request.user.attributes`, switch those two expressions to read them.
- **IdP-initiated** is what the dashboard tile now does (`meta_launch_url` →
  `…/application/saml/label-studio/init/`), so clicking the tile signs you in
  rather than dropping you on Heartex's login page to retype the company domain.
  Note the tradeoff: an unsolicited assertion carries no `InResponseTo`, so it
  can't be bound to a request the SP issued — the usual login-CSRF caveat for
  IdP-initiated SAML. Acceptable here (Label Studio is a labeling tool, not a
  control plane); don't copy this to Fleet, which is the device control plane.
  SP-initiated keeps working either way — it's the fallback if the tile regresses.
- **App icon** is Label Studio's "Heidi the opossum" mascot mark, vendored from the
  HumanSignal repo (dashboard-icons has no entry) — see the media-icons README.
- **Deprovisioning:** SAML SSO authenticates but doesn't deprovision — removing a
  user from AD stops new logins but doesn't disable their Label Studio account.
  Label Studio Enterprise also supports SCIM for lifecycle; out of scope here.

## If this needs to be parked again

1. `git revert` the commit that restored `terraform/authentik/label_studio.tf` +
   the icon (or mirror `b1b6a9d`'s shape: remove the `.tf` file, the icon, the
   README row/footnote, and rewrite this doc back to a parked-status diagnosis
   with whatever new evidence support provided).
2. `tofu apply` to tear down the Authentik-side provider/application/mappings.
3. Leave the `Label Studio Admins` AD group in `spec/krg-ad/groups.yml` — it's the
   role gate for the next attempt and removing it only creates drift (apply never
   deletes groups).
4. Update the tracking issue (#326, reopened if closed) with the new failure
   evidence so the next attempt doesn't repeat this one's dead ends.
