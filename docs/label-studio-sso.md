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

## Authentik side (IaC)

`terraform/authentik/label_studio.tf`:
- `authentik_provider_saml.label_studio` — assertion-signed with the default
  self-signed keypair (`data.authentik_certificate_key_pair.default`); HTTP-POST
  binding; `acs_url`/`audience` from `locals.label_studio_acs_url` (inlined).
- Five SAML attribute statements emitting exactly what Label Studio's **default**
  preset reads:

  | SAML `Name` | value (Authentik expression)                       |
  |-------------|----------------------------------------------------|
  | NameID      | `request.user.email` (subject)                     |
  | `Email`     | `request.user.email`                               |
  | `FirstName` | first token of `request.user.name`                 |
  | `LastName`  | rest of `request.user.name`                        |
  | `Groups`    | `[g.name for g in request.user.ak_groups.all()]`   |

- `authentik_application.label_studio` — slug **`label-studio`** (load-bearing: the
  metadata/SSO URLs embed it), dashboard tile → `app.heartex.com`.

The slug fixes the URLs you hand Label Studio:
- **Metadata URL:** `https://auth.krg.ucsd.edu/api/v3/providers/saml/<pk>/metadata/?download`
  (or grab it from the provider page in the Authentik admin UI — *Providers → Provider
  for Label Studio Enterprise → Download metadata / Copy download URL*).
- **SSO (redirect) URL:** `https://auth.krg.ucsd.edu/application/saml/label-studio/sso/binding/redirect/`

### SP endpoints

The org's ACS URL / Audience are **committed inline** in `label_studio.tf`
(`locals.label_studio_acs_url`) — they're non-secret endpoint URLs in the same
class as every other service URL in this layer (they carry only the org id, are
exchanged in SAML metadata, and grant nothing without the IdP signing key). This
org reports the **same URL for both** the ACS and the Audience/EntityID. If you
ever rotate the org or it splits them, edit that local.

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
   `Groups` to Label Studio org roles / workspaces / projects. The names must match
   the AD group names byte-for-byte (see `groups.tf` — groups are AD-sourced; create
   them with `samba-tool` on krg-ldap, not as local Authentik groups).
5. **Test.** From the Authentik dashboard tile (→ `app.heartex.com`, SP-initiated
   SSO back to us), and directly via Label Studio's **Login URL**. Confirm a fresh
   AD user lands with the expected role from their group mapping.

## Notes / gotchas

- **First/last name** come from a whitespace split of the single Authentik display
  name (`request.user.name`); they only populate the Label Studio display name —
  identity is the email. If the AD sync ever lands `givenName`/`sn` into
  `request.user.attributes`, switch those two expressions to read them.
- **IdP-initiated** login is not wired (the tile sends users to Label Studio, which
  SP-initiates). To enable true IdP-initiated SSO later, set `default_relay_state` on
  the provider and confirm Label Studio accepts unsolicited responses.
- **App icon** is Label Studio's "Heidi the opossum" mascot mark, vendored from the
  HumanSignal repo (dashboard-icons has no entry) — see the media-icons README.
- **Deprovisioning:** SAML SSO authenticates but doesn't deprovision — removing a
  user from AD stops new logins but doesn't disable their Label Studio account.
  Label Studio Enterprise also supports SCIM for lifecycle; out of scope here.
