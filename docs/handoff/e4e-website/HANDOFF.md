# website2.0: publish-slot hand-off

For the maintainers of [UCSD-E4E/website2.0](https://github.com/UCSD-E4E/website2.0).

The site used to be published by `deploy@kastner-ml`. That box has been rebuilt and the
deploy user is gone. Jacobs hosting (`mywebsite.eng.ucsd.edu`) only accepts SSH from
campus, so a GitHub-hosted runner can't publish directly. The lab now gives the site a
small **Incus slot** on krg-nat, `e4e-website`, whose self-hosted runner does the
publish. The platform side is in krg-infra:
[`docs/onboarding-e4e-website.md`](../../onboarding-e4e-website.md).

## 1. How a publish works

1. Push to `main`. `build` runs on `ubuntu-latest` exactly as before, then uploads
   `_site/` as the artifact `site`.
2. `deploy` runs on the slot's runner (`[self-hosted, e4e-website]`). It waits out any
   publish still running, downloads the artifact into
   `/var/lib/e4e-website/staging/incoming`, renames it to `staging/site`, and starts
   `e4e-website-publish`.
3. That unit rsyncs `staging/site` to `e4e@mywebsite.eng.ucsd.edu:htdocs/` (`--delete`,
   the same as the old script). It refuses a site without `index.html` and
   `last_deployed.txt`. The step "Publish log" prints what it did.

Pushes to `main` queue rather than cancel each other (a cancelled deploy would abandon
a publish mid-rsync). Other branches still cancel superseded builds.

**No secrets in this repo.** The SSH key lives in the lab's OpenBao and only the
publish unit can read it. Delete the old `KASTNER_ML_DEPLOY_SSH` /
`KASTNER_ML_KNOWN_HOSTS` repo secrets once this is live.

Other branches still build and check on GitHub-hosted runners. Only `main` publishes.

## 2. Files to copy in

| File | What |
|---|---|
| `flake.nix` | the slot's config: `mkTenant { name = "e4e-website"; … }` + `deploy/incus/publish.nix`. Run `nix flake lock` once and commit `flake.lock` too. |
| `deploy/incus/publish.nix` | the publish unit, its SSH key render, the pinned mywebsite host key, the runner's one writable path |
| `.github/workflows/jekyll.yml` | **replaces** yours: queues (not cancels) runs on main, adds the build stamp + artifact upload, swaps the `deploy` job to the slot |
| `.github/workflows/converge.yml` | rebuilds the slot when `flake.nix`/`flake.lock`/`deploy/incus/` change on main |
| `.github/workflows/update-flake.yml` | weekly krg-infra pin bump: how the slot gets OS security patches. Don't disable it. |

Then **delete `_deploy_e4e-dev.sh`**. The build stamp (`last_deployed.txt`) now comes
from the `build` job.

`jekyll.yml` here is your 2026-10-15 file (blob `c6a8080`) with only those changes. If
yours has moved on since, apply the same three edits by hand.

## 3. One-time repo settings

- `update-flake.yml` pushes `flake.lock` to `main`, so it needs a GitHub App
  (`vars.APP_ID` + `secrets.APP_PRIVATE_KEY`) allowed to bypass branch protection. The
  UCSD-E4E org App used by the other tenant repos works once it's installed here.
- **Fork PRs must not reach the slot.** The self-hosted job only runs on `main` pushes,
  but keep Settings → Actions → General → "Require approval for all outside
  collaborators" on, and never add `runs-on: [self-hosted, …]` to a `pull_request`
  workflow.

## 4. Order

The slot doesn't exist until the lab flips it on. Land these files whenever you like:
until then, `deploy` sits **queued** with no runner and nothing breaks. (Cancel queued
runs before the flip, onboarding §3.) After the flip, the next push to `main` publishes.
