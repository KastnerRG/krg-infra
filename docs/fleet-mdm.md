# Fleet — endpoint device management / MDM

Self-hosted [Fleet](https://github.com/fleetdm/fleet) is the lab-owned control
plane for lab-owned endpoints, per [ADR 0012](adr/0012-endpoint-device-management.md):
FDE key escrow, remote lock/wipe, OS/app update enforcement, and config profiles
for the **MDM-capable** platforms (macOS, Windows, iOS/iPadOS, Android). **NixOS
devices are NOT managed here** — the flake owns them (LUKS + `system.autoUpgrade`).

- **Scope:** lab-owned equipment only. Personal/BYOD devices are never enrolled.
- **URL:** `mdm.e4e.ucsd.edu` (CNAME → krg-prod). E4E-namespaced because E4E owns the
  first devices; the stack itself is lab-wide on krg-prod. Rename anchor = the Traefik
  router rule in `nix/docker-compose/krg-prod/compose.fleet.yml`.

## Architecture

Runs as part of the krg-prod compose project (`compose.fleet.yml`, `include:`-d from
`compose.yml`), behind Traefik with Let's Encrypt TLS:

- `fleet` — the server (`fleet serve`), plain HTTP `:8080`, TLS terminated at Traefik.
- `fleet_mysql` (MySQL 8.4) + `fleet_valkey` (Valkey) on the private `fleet` network.
- `fleet_migrate` — one-shot `fleet prepare db` that the server waits on
  (`service_completed_successfully`); idempotent, runs on every `up`.

**Datastore choices.** Fleet uses MySQL extensively and only *experimentally* supports
MariaDB (formal support tracked in fleetdm/fleet #27400, #31288) — so the DB stays
**MySQL 8.4** (the Fleet-tested LTS) until MariaDB is supported. The cache is
**Valkey** (`valkey/valkey`), which Fleet documents as its *recommended*
Redis-compatible cache; it's wire-compatible, so `FLEET_REDIS_ADDRESS` is unchanged.

## Secrets

Fully IaC — **no `.secrets/` file, no operator seeding.** `terraform/secrets/fleet.tf`
generates them (`random_password`) and writes them to OpenBao at
`secret/krg-prod/authentik-managed/fleet`; `krg.vaultAgent` renders them to `/run` on
krg-prod (`/run/krg/fleet/db.env` for MySQL, `/run/krg/fleet/server.env` for Fleet),
and the stack fails closed if OpenBao is unreachable — same contract as the rest of
the project. (The `authentik-managed/` path is just the policy-globbed krg-prod
namespace; Fleet's SSO is SAML, nothing Authentik-minted lives there.)

| Key | Var(s) | Notes |
|-----|--------|-------|
| `mysql_root_password` | `MYSQL_ROOT_PASSWORD` | MySQL root |
| `db_password` | `MYSQL_PASSWORD` + `FLEET_MYSQL_PASSWORD` | the `fleet` DB role; one value, two names |
| `server_private_key` | `FLEET_SERVER_PRIVATE_KEY` | encrypts MDM assets at rest |

> **`server_private_key` is load-bearing and generate-once:** Fleet encrypts MDM
> certs/keys at rest with it. `fleet.tf` never rotates it (it's persisted in OpenBao +
> tofu state) — regenerating bricks MDM enrollment and you'd have to re-enroll every
> device. That's *why* it lives in tofu/OpenBao, not a hand-placed file.

## SSO (Authentik, SAML)

Fleet's console SSO is **SAML 2.0 only** (not OIDC like the rest of the lab) — Fleet
keys users on the SAML NameID and requires it to be their **email**. The IdP side is
IaC in `terraform/authentik/` (`tofu apply` there):

- `authentik_provider_saml.fleet` + `authentik_application.fleet` (`applications_e4e.tf`),
  using the default SAML email/username/name mappings (`data.tf`). ACS =
  `https://mdm.e4e.ucsd.edu/api/v1/fleet/sso/callback`, audience/entity_id =
  `https://mdm.e4e.ucsd.edu`, signed with Authentik's default keypair.

The **Fleet side** is app config (DB-stored — set via the UI at bring-up, or the
`fleetctl gitops` layer when it lands). Values:

```yaml
org_settings:
  sso_settings:
    enable_sso: true
    enable_sso_idp_login: true
    enable_jit_provisioning: true          # Fleet Premium only; false on Free
    idp_name: Authentik
    entity_id: https://mdm.e4e.ucsd.edu     # MUST match the provider audience
    metadata_url: https://auth.krg.ucsd.edu/application/saml/fleet/metadata/
```

> Confirm the exact `metadata_url` on the Authentik provider's page at bring-up.
> **Restrict console access** to a Fleet-admins AD group (an `authentik_policy_binding`)
> — Fleet is the device control plane, don't leave it open to all AD users.

## OOBE gate (REMOVED — history)

Fleet's first-run setup wizard is **unauthenticated**: whoever reaches it first becomes
**superadmin** of the device control plane. So until an admin existed, `mdm.e4e.ucsd.edu`
was fronted by an **Authentik forward-auth gate** (the `guacamole_gate` pattern) bound to
**Domain Admins**, so only admins could reach the wizard. The pieces were:
- `authentik_provider_proxy.fleet_gate` + `authentik_application.fleet_gate` + the
  `fleet_gate_admins` policy binding (`terraform/authentik/applications_e4e.tf`),
- registered on the proxy outpost (`terraform/authentik/outpost.tf`),
- the `traefik.http.routers.fleet.middlewares=authentik` label (`compose.fleet.yml`).

**The gate has been removed** now that the break-glass admin exists (so the wizard is
closed) — it also **blocks Fleet's own API**: the forward-auth 302 to Authentik's OIDC
`authorize` endpoint fails the SPA's cross-origin XHR, so the SSO settings save returns
*"Could not update settings"* while it's up (and it blocks roaming devices' HTTP
API/enrollment, which can't do a browser SSO redirect). That's why the sequence is
**create admin → remove gate → configure SSO**, not gate-then-SSO. Removal = delete those
four pieces, `tofu apply` (authentik) via `deploy-tofu.sh`, and redeploy krg-prod; the
login page is then guarded by the local admin (and, once configured, SAML SSO).

## Bring-up

The stack is wired in (`compose.fleet.yml` `include:` + the `mdm.e4e.ucsd.edu` Traefik
alias are enabled) and the icon is shipped, so:

1. **Verify the image pin.** Confirm `fleetdm/fleet:vX.Y.Z` in `compose.fleet.yml` is
   current (both `fleet` and `fleet_migrate` — keep them in lockstep).
2. **`tofu apply`** — `terraform/secrets` (generates the Fleet secrets into OpenBao,
   which the krg-prod vault-agent renders at deploy) **and** `terraform/authentik` (the
   SAML provider/app + icon registration). In the fleet deploy pipeline these are the
   OpenTofu phases and run automatically.
3. **Deploy** krg-prod (the 04:00 `autoUpgrade` tick, or `nixos-rebuild … --target-host
   krg-prod`). vault-agent renders `/run/krg/fleet/{db,server}.env` (fail-closed if
   OpenBao is down) and the fleet services come up behind Traefik.
4. **Create the admin** while the OOBE gate is up (Domain-Admins-only): browse to
   `https://mdm.e4e.ucsd.edu`, create the admin user, and set the Fleet **server URL** to
   `https://mdm.e4e.ucsd.edu`.
5. **Remove the OOBE gate** (see the section above) — the gate blocks the SSO settings
   save (and device enrollment), so it must come down *before* the next step.
6. **Configure SSO:** UI → Settings → Integrations → Single sign-on (SSO), Fleet-users
   tab, with the values from the SSO section above, then **Save**. On Fleet Free
   (no JIT), also pre-create each SSO user under **Users** with a matching AD email.

## Follow-ups (own PRs / issues)

- **`fleetctl gitops` layer + runner** — declarative teams / policies / FDE-enforcement /
  OS-update policy / the macOS Kerberos SSO Extension profile (realm `KRG.LOCAL`), plus
  the `fleetctl gitops` runner on krg-deploy (PR #85-style timer). Fold the SSO
  `sso_settings` above into it.
- **MDM enrollment externals** (the appliance-style break-glass exception per ADR 0012):
  Apple **APNs cert** + **Apple Business Manager** (macOS/iOS/iPadOS); **Android
  Enterprise** binding; Fleet's **WSTEP** (Windows). All operator/credentialed steps.
- **Intune coordination** — keep loaners Intune-exempt (eduroam, not UCSD-PROTECTED) to
  retain lab wipe/config control; no dual-MDM. Don't run `oec_qualys_trellix` on any
  Intune-managed device (ADR 0012 / ADR 0006).
