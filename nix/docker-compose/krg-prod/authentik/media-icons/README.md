# Authentik application icons

App-tile icons shown on the Authentik user dashboard (`auth.krg.ucsd.edu`).

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
| `garage.svg`          | Garage UI            | `garage`                 |
| `apache-superset.svg` | FishSense Analytics  | `apache-superset`        |
| `vaultwarden.svg`     | Vaultwarden          | `vaultwarden`            |

Not yet iconed (no clean off-the-shelf logo in dashboard-icons — follow-up):
FishSense Workflows (Temporal), FishSense (main), FishSense Orchestrator,
Qualcomm Docs, KRG Roster.
