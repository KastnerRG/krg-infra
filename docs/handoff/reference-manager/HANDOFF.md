# reference-manager: tenant hand-off (bib.krg.ucsd.edu)

For the maintainers of [UCSD-E4E/e4e-reference-manager](https://github.com/UCSD-E4E/e4e-reference-manager).
The lab platform gives the app an **Incus slot**, the same kind fishsense runs on. The
platform side (the slot, its secrets, Authentik, the public route) is in krg-infra and
described in [`docs/onboarding-reference-manager.md`](../../onboarding-reference-manager.md).
**The app repo owns everything inside the slot**: this directory is that interior,
ready to copy in. It mirrors fishsense-services' layout, so the fishsense repos are a
working reference for anything not covered here.

## 1. How a deploy works

1. You tag `vX.Y.Z`. `release.yml` builds and pushes
   `ghcr.io/ucsd-e4e/e4e-reference-manager-{api,web}:vX.Y.Z`, then opens a PR
   `auto-deploy/vX.Y.Z` that bumps the two pins in `deploy/incus/compose.yml`.
2. A human merges that PR.
3. `deploy.yml` runs on the slot's own self-hosted runner (label
   `[self-hosted, reference-manager]`). It starts `reference-manager-selfupdate`, which runs
   `nixos-rebuild switch --flake github:UCSD-E4E/e4e-reference-manager#reference-manager`.
   That rebuilds the slot from this repo's `flake.nix` and brings the compose stack up
   on the new pins. `verify-incus` then checks that the deployed pins match `main`
   and that the stack unit succeeded.

Config-only changes (e.g. `deploy/incus/traefik-dynamic.yml`) go live with
`workflow_dispatch` on `deploy.yml`. `update-flake.yml` bumps the krg-infra pin weekly;
that's how the slot gets OS security patches. Don't disable it.

## 2. Files to copy into the app repo

Paths here are repo-relative and land at the same path in the app repo.

| File | What |
|---|---|
| `flake.nix` | the deploy target: `mkTenant { name = "reference-manager"; zone = "krg"; … }` + this directory's modules. Run `nix flake lock` once to create `flake.lock`, and commit both. |
| `deploy/incus/compose.yml` | the interior: traefik, api, web, postgres, translation-server, grobid, ollama (+ `ollama-models`), `pg-dump` + `pg-backup-sync` |
| `deploy/incus/traefik-dynamic.yml` | the inner Traefik: `/api/*` → api (prefix stripped), everything else → web |
| `deploy/incus/secrets.nix` | the env files vault-agent renders from OpenBao, one per consumer |
| `deploy/incus/workdir.nix` | links committed config into the compose project directory |
| `deploy/incus/prune.nix` | reclaims superseded images after each converge |
| `.github/workflows/{build,release,deploy,update-flake}.yml` | CI, release + pin bump, converge + verify, weekly krg-infra pin bump |
| `web/Dockerfile`, `web/nginx.conf` | the production web image (static build behind nginx) |

`api/Dockerfile` already exists; change it as in §6.

## 3. One-time repo settings

- **Make the repository public** (or see onboarding §3.5). The slot fetches the flake
  anonymously, so a private repo can't deploy.
- After the first release, make both GHCR packages **public** (Package settings →
  Change visibility). The slot pulls without credentials.
- Settings → Actions → General → **Allow GitHub Actions to create and approve pull
  requests**, so `release.yml` can open the `auto-deploy/*` PR.
- `update-flake.yml` needs `vars.APP_ID` + `secrets.APP_PRIVATE_KEY` for a GitHub App
  that may push to `main` (fishsense-services uses the same setup).
- The lab admin installs the org's runner GitHub App on this repo.

## 4. Secrets: nothing to seed

Everything the slot reads is written by krg-infra IaC:

| OpenBao path | Fields | Written by |
|---|---|---|
| `tenants/reference-manager/generated/app` | `db_password`, `session_secret` | `terraform/secrets` (generate-once) |
| `tenants/reference-manager/oidc/web` | `client_id`, `client_secret`, `issuer_url` | `terraform/authentik` |
| `e4e-nas/garage-keys/reference-manager` | `access_key_id`, `secret_access_key` | the e4e-nas deploy (the Garage key) |

vault-agent is **fail-closed**: if any of those paths is missing, the whole stack
(the TLS cert included) stays down. Don't add a render for a path that doesn't exist
yet.

## 5. Settings the API runs with

From `compose.yml` (non-secret) plus `secrets.nix` (secret), matching the app's
`REFMAN_*` settings:

```
REFMAN_APP_BASE_URL=https://bib.krg.ucsd.edu/api
REFMAN_CORS_ORIGINS=[]                         # same origin; no CORS
REFMAN_DATABASE_URL=postgresql+asyncpg://refman:<pw>@postgres:5432/refman   # secret
REFMAN_S3_ENDPOINT_URL=https://s3.e4e.ucsd.edu
REFMAN_S3_PUBLIC_ENDPOINT_URL=https://s3.e4e.ucsd.edu
REFMAN_S3_REGION=garage                        # MUST be garage (SigV4)
REFMAN_S3_BUCKET=reference-manager
REFMAN_S3_ACCESS_KEY / REFMAN_S3_SECRET_KEY    # secret (the Garage key)
REFMAN_SESSION_SECRET                          # secret
REFMAN_DEV_AUTH=false
REFMAN_OIDC_ISSUER=https://auth.krg.ucsd.edu/application/o/reference-manager/   # from oidc/web
REFMAN_OIDC_CLIENT_ID / REFMAN_OIDC_CLIENT_SECRET   # secret
REFMAN_OIDC_REDIRECT_URI=https://bib.krg.ucsd.edu/api/auth/callback
REFMAN_POST_LOGIN_REDIRECT=https://bib.krg.ucsd.edu/
REFMAN_TRANSLATION_SERVER_URL=http://translation-server:1969
REFMAN_GROBID_URL=http://grobid:8070
REFMAN_OLLAMA_URL=http://ollama:11434
```

The API command is
`uv run alembic upgrade head && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --root-path /api`,
with `UV_NO_SYNC=1`. No `--reload` and no source bind mounts.

## 6. App changes needed for production

Checked against `main` at `a5bc13f` by building both images and running them.

1. **Blocker: the service worker breaks login.** `web/vite.config.ts`
   `workbox.navigateFallbackDenylist` lists the dev paths (`/auth`, `/libraries`, …),
   but in production the API lives under `/api`. Once the SW installs, a navigation to
   `/api/auth/login` gets `index.html` instead of the redirect to Authentik. Add
   `/^\/api\//` to the denylist. (Confirmed in the built `sw.js`.)
2. **`api/Dockerfile`: install the project and lock the dependencies.** It copies
   `pyproject.toml` but not `uv.lock`, and runs `uv sync --no-install-project`. So the
   image resolves dependencies fresh at build time, and `uv run` at container start
   installs the project, downloading `hatchling` from PyPI on every start (confirmed:
   with no network the container can't start). Copy `uv.lock`, and after copying `app/`
   run `uv sync --frozen --no-dev`. The interior sets `UV_NO_SYNC=1` meanwhile, which
   works (verified offline).
3. **Request the `groups` scope.** `register_oidc` asks for `openid email profile`, so
   the `groups` claim never arrives, and group sync and `OIDC_ADMIN_GROUP` see `[]`.
   The Authentik provider already carries the lab's `groups` mapping; it emits only
   when asked. Use `"openid email profile groups"`.
4. **Add `web/Dockerfile` + `web/nginx.conf`** from this directory. Vite bakes
   `VITE_API_URL` at build time; `release.yml` passes `/api`. Verified: the build has
   no `localhost:8000` left, serves the SPA fallback, and serves the manifest as
   `application/manifest+json`.
5. **Recommended:** `SessionMiddleware(..., https_only=True)` in production, so the
   session cookie carries `Secure`.
6. **Good to know:** at startup the API's `ensure_bucket` blocks for about a minute if
   S3 is unreachable. The Garage key can't create buckets, which is fine: the bucket
   already exists.

## 7. Operating notes

- **Logs**: `docker logs reference-manager-<service>-1` on the slot (admin access:
  `incus exec reference-manager --project reference-manager -- …` on krg-nat).
- **Models**: `ollama-models` pulls `nomic-embed-text` + `qwen2.5:3b` on every converge
  (a no-op once present). Changing `embedding_model` / `llm_model` in the app means
  changing that command too. A different embedding width needs a migration.
- **Backups**: `pg-dump` writes `refman-<UTC>.dump` (custom format) daily and keeps 14.
  `pg-backup-sync` mirrors them to `s3://reference-manager/_backups/postgres/` hourly.
  To restore one (on the slot):
  ```bash
  docker stop reference-manager-api-1
  docker exec -i reference-manager-postgres-1 pg_restore -U refman -d refman --clean --if-exists < refman-<ts>.dump
  systemctl restart reference-manager.service   # brings the API back via the normal converge
  ```
  (Pull the file back from Garage with any S3 client first if the slot's volume is
  gone.)
- **Never rotate `generated/app.db_password` on a live slot.** The postgres image
  applies it only when initialising an empty volume; afterwards the password lives in
  the database, and a new value just locks the API out.
- **Disk**: 60 GiB. GROBID and Ollama are the big images; `prune.nix` reclaims
  superseded ones older than 72 h.
