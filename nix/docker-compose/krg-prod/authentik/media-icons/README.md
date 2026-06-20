# Authentik application icons

App-tile icons shown on the Authentik user dashboard (`auth.krg.ucsd.edu`).

**Convention: every third-party application surfaced in Authentik should ship an
icon here.** An iconless tile renders as a generic placeholder and reads as a
broken/untrusted link. When you add an app to `terraform/authentik/applications_*.tf`,
add its icon in the same change (or, if no clean upstream logo exists yet, record
it in the "Not yet iconed" list below so the gap is tracked, not forgotten).

## How they're wired

Authentik 2026.2 serves application icons from its file-manager media store at
`/data/media/public/<name>` (the old `/media` path was retired this release —
see authentik PR #18829). This directory is mounted **read-only** into that path
as `krg-icons/`:

- `nix/hosts/krg-prod/default.nix` symlinks the working dir
  `…/authentik/media-icons` → this Nix store directory, and pre-creates
  `…/authentik/data/media/public` (owned by the authentik uid) so the bind below
  lands inside a writable parent.
- `compose.authentik.yml` bind-mounts `./authentik/media-icons` →
  `/data/media/public/krg-icons:ro` on the server + worker.
- `terraform/authentik/applications_*.tf` set `meta_icon = "krg-icons/<file>.svg"`
  per application.

To add/replace an icon: drop the SVG here, `git add` it, point the app's
`meta_icon` at `krg-icons/<file>.svg`, then `nixos-rebuild` (krg-prod) and
`tofu apply` (terraform/authentik).

## Source & licensing

SVGs vendored from [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons)
(repo licensed permissively; each logo remains the trademark of its respective
owner — used here only to label first-party links to those services).

| File                  | App / service        | Upstream name            |
|-----------------------|----------------------|--------------------------|
| `grafana.svg`         | Grafana              | `grafana`                |
| `outline.svg`         | Outline              | `outline`                |
| `mlflow.svg`          | MLflow               | `ml-flow-wordmark`       |
| `synology.svg`        | E4E NAS (Synology)   | `synology`               |
| `garage.svg`          | E4E Garage UI        | `garage`                 |
| `apache-superset.svg` | FishSense Analytics  | `apache-superset`        |
| `fishsense.svg`       | FishSense (+ Orchestrator) | (UCSD-E4E asset)² |
| `vaultwarden.svg`     | Vaultwarden          | `vaultwarden`            |
| `guacamole.svg`       | Guacamole            | `apache-guacamole`       |
| `temporal.svg`        | Temporal             | (Temporal brand assets)¹ |
| `proxmox.svg`         | Proxmox              | `proxmox`                |

¹ `temporal.svg` is Temporal's official "Symbol (dark)" mark from the Temporal
brand assets, not dashboard-icons. Note it's a near-black (`#141414`) glyph — fine
on a light dashboard, low-contrast on the dark theme; swap for a light variant if
that reads poorly.

² `fishsense.svg` is the FishSense project's own logo (the `fishsense-lite-web`
public asset, github.com/UCSD-E4E/fishsense-lite), not dashboard-icons — a
first-party mark for a first-party app. It's a wide wordmark (207×123), so it
scales down inside the square tile. Shared by the FishSense site and the
FishSense Orchestrator (no orchestrator-specific logo exists).

Not yet iconed (no clean off-the-shelf logo in dashboard-icons — follow-up):
KRG Roster.
