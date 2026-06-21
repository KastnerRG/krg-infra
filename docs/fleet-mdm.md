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
- `fleet_mysql` (MySQL 8.4) + `fleet_redis` (Redis) on the private `fleet` network.
- `fleet_migrate` — one-shot `fleet prepare db` that the server waits on
  (`service_completed_successfully`); idempotent, runs on every `up`.

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

## Bring-up

1. **Verify the image pin.** Bump `fleetdm/fleet:vX.Y.Z` in `compose.fleet.yml` to the
   current stable release (both `fleet` and `fleet_migrate` — keep them in lockstep).
2. **Seed** `/var/lib/krg/krg-prod/.secrets/fleet.env` (above).
3. **Enable** the stack: uncomment `- compose.fleet.yml` (include list) and
   `- mdm.e4e.ucsd.edu` (Traefik aliases) in `compose.yml`; commit + push + deploy
   (the 04:00 `autoUpgrade` tick, or `nixos-rebuild ... --target-host krg-prod`).
4. **Initial setup:** browse to `https://mdm.e4e.ucsd.edu`, create the admin user, and
   set the Fleet **server URL** to `https://mdm.e4e.ucsd.edu`.

## Follow-ups (own PRs / issues)

- **Authentik SSO** — add a Fleet OIDC app/provider in `terraform/authentik/` + an
  app-tile icon (CLAUDE.md §4); wire Fleet SSO env to the generated client secret.
- **`fleetctl gitops` layer** — declarative teams / policies / FDE-enforcement / OS-update
  policy / the macOS Kerberos SSO Extension profile (realm `KRG.LOCAL`).
- **MDM enrollment externals** (the appliance-style break-glass exception per ADR 0012):
  Apple **APNs cert** + **Apple Business Manager** (macOS/iOS/iPadOS); **Android
  Enterprise** binding; Fleet's **WSTEP** (Windows). All operator/credentialed steps.
- **Intune coordination** — keep loaners Intune-exempt (eduroam, not UCSD-PROTECTED) to
  retain lab wipe/config control; no dual-MDM. Don't run `oec_qualys_trellix` on any
  Intune-managed device (ADR 0012 / ADR 0006).
- **Secrets → `krg.vaultAgent`** — migrate `fleet.env` off `.secrets/` to /run renders.
