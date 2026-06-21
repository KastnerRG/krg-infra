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

Hand-placed in `/var/lib/krg/krg-prod/.secrets/fleet.env` (gitignored). Migrate to
`krg.vaultAgent` once bao-seeded — the rest of the project already renders from /run.

```
MYSQL_ROOT_PASSWORD=<random>
MYSQL_PASSWORD=<random>            # the `fleet` DB-role password
FLEET_MYSQL_PASSWORD=<same as MYSQL_PASSWORD>
FLEET_SERVER_PRIVATE_KEY=<>=32 random chars>
```

> **`FLEET_SERVER_PRIVATE_KEY` is load-bearing:** Fleet encrypts MDM certificates and
> keys at rest with it. **Back it up** — losing it bricks MDM enrollment and you must
> re-enroll every device. Generate with e.g. `openssl rand -base64 32`.

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

## Bring-up

1. **Verify the image pin.** Confirm `fleetdm/fleet:vX.Y.Z` in `compose.fleet.yml` is
   current (both `fleet` and `fleet_migrate` — keep them in lockstep).
2. **Seed** `/var/lib/krg/krg-prod/.secrets/fleet.env` (above).
3. **`tofu apply`** in `terraform/authentik/` to create the SAML provider + app.
4. **Enable** the stack: uncomment `- compose.fleet.yml` (include list) and
   `- mdm.e4e.ucsd.edu` (Traefik aliases) in `compose.yml`; commit + push + deploy
   (the 04:00 `autoUpgrade` tick, or `nixos-rebuild ... --target-host krg-prod`).
5. **Initial setup:** browse to `https://mdm.e4e.ucsd.edu`, create the admin user, set
   the Fleet **server URL** to `https://mdm.e4e.ucsd.edu`, and apply the SSO settings
   above (UI → Settings → Organization settings → SSO).

## Follow-ups (own PRs / issues)

- **App-tile icon** — add `fleet.svg` to `authentik/media-icons/` and set `meta_icon`
  (CLAUDE.md §4); tracked in that dir's README "Not yet iconed".
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
- **Secrets → `krg.vaultAgent`** — migrate `fleet.env` off `.secrets/` to /run renders.
