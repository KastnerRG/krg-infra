# Onboarding e4e-website: the E4E website's publish agent

The E4E website ([UCSD-E4E/website2.0](https://github.com/UCSD-E4E/website2.0), Jekyll)
is served by **Jacobs web hosting**: account `e4e` on `mywebsite.eng.ucsd.edu`, docroot
`htdocs/`. Until the kastner-ml rebuild, `deploy@kastner-ml` rebuilt and pushed it:
GitHub Actions SSH'd in and ran `_deploy_e4e-dev.sh`, which built with rbenv/nvm and
sshfs-rsynced `_site/`. The NixOS kastner-ml dropped that toolchain
([kastner-ml-onboarding.md](kastner-ml-onboarding.md): "E4E web-deploy retired"), so
the site has had no publish path since.

The new landing spot is Incus tenant **`e4e-website`** on krg-nat. It is a slot like
fishsense and reference-manager, but it runs **no app and has no edge**: its runner is
the campus-side hop.

This runbook is the admin's half. The repo's half is
[handoff/e4e-website/HANDOFF.md](handoff/e4e-website/HANDOFF.md).

## Why a slot (and not GitHub-hosted)

`mywebsite.eng.ucsd.edu:22` **only answers from campus**. On 2026-10-15 it timed out
from an off-campus IP but served its host keys to `ssh-keyscan` from waiter
(137.110.161.67). A GitHub-hosted runner can't reach it. A krg-nat slot egresses
SNAT'd as krg-nat (137.110.161.105, same campus /24 as waiter), so it can.

## The shape

```
push to main ─▶ build (ubuntu-latest): gulp/Jekyll build, link checks, htmlproofer
                └─ upload-artifact "site" (_site/, incl. .htaccess)
             ─▶ deploy (runs-on [self-hosted, e4e-website], the krg-nat slot)
                ├─ wait out any in-flight publish
                ├─ download-artifact → staging/incoming, then rename → staging/site
                │    (/var/lib/e4e-website/staging: the runner's one RW path)
                └─ systemctl start e4e-website-publish   (polkit: verb "start", this unit only)
                     user e4e-website-publish, key via LoadCredential
                     rsync -r -c --delete ─ssh─▶ e4e@mywebsite.eng.ucsd.edu:htdocs/
```

The **build stays on GitHub-hosted CI**. A tenant runner is deliberately weak
(`nix/modules/tenant.nix`: no docker, no sudo, "builds belong in GitHub-hosted CI"),
and this one only stages files and starts a unit. The **SSH key never reaches the
runner**. Anyone who can push a workflow can make it publish whatever they like (as
they could by merging), but they can't take the key off the box.

## 1. What this PR lands (inert)

| Piece | Where | State on merge |
|---|---|---|
| Boundary: Incus project + quota (2 CPU / 4 GiB / 20 GiB) | `terraform/incus` `var.tenants.e4e-website` | CD creates the **project only** (`image = ""`) |
| OpenBao AppRole `tenant-e4e-website` (reads `tenants/e4e-website/*`) | `terraform/openbao` `var.tenants.e4e-website` | nothing (CD never applies `openbao`); gate 2 |
| SSH keypair `tenants/e4e-website/generated/mywebsite-ssh` `{private_key, public_key}` | `terraform/secrets/e4e_website.tf` (new `hashicorp/tls` provider) | CD generates it (krg-deploy's `tenants/+/generated` glob) |
| Copy-in interior: `flake.nix`, `deploy/incus/publish.nix`, workflows | `docs/handoff/e4e-website/` | docs only |

No nat_ip, no edge_port, no edge route, no Authentik app, no DNS: nothing reaches the slot
from outside.

## 2. Gates before the flip

1. **This PR merged and deployed.** Check that the `secrets` target created the keypair
   (keys only): `bao kv get -format=json secret/tenants/e4e-website/generated/mywebsite-ssh | jq -c '.data.data|keys'`
   → `["private_key","public_key"]`. Check that the post phase actually ran, not just
   the run's conclusion (a no-downgrade skip also reports `success`).
2. **Privileged OpenBao apply** (creates the AppRole + policy), same procedure as
   [onboarding-reference-manager.md §3.3](onboarding-reference-manager.md). Expected
   plan: **2 to add, 0 to change**: `vault_policy.tenant["e4e-website"]` and
   `vault_approle_auth_backend_role.tenant["e4e-website"]`.
3. **Install the public key on mywebsite.** It's the one step outside IaC: the host is
   ETS-run.
   ```bash
   bao kv get -field=public_key secret/tenants/e4e-website/generated/mywebsite-ssh
   ```
   Append that one line to `~e4e/.ssh/authorized_keys` on mywebsite (log in as `e4e`
   from campus with an existing credential). Remove the old kastner-ml key
   (`id_e4edev`) while you're there: its private half was on a box that's been wiped.
4. **website2.0 carries the interior** (HANDOFF §2), with `flake.lock` committed and
   pinning a krg-infra rev that contains this PR.
5. **The runner GitHub App is installed on UCSD-E4E/website2.0.** On krg-deploy:
   `./deploy/mint-runner-token.sh --is-registered UCSD-E4E/website2.0 e4e-website`
   must answer `NOT registered` (rc=1), not `could not list runners`.
6. **website2.0 is public.** ✅ (it is; the slot fetches the flake anonymously).

## 3. The flip PR

One line in `terraform/incus` `var.tenants.e4e-website`:

```hcl
image = "krg-golden"
```

Merge only **after** gate 2. If it merges earlier, phase 3.6 skips the slot ("AppRole not
found": a warning, not a red deploy). CD then creates the instance (DHCP on the NAT; no
forward) and stages secret-zero + a runner registration token.

**Before the first converge, cancel any QUEUED `deploy` jobs in website2.0.** Each push
to main queues one against `[self-hosted, e4e-website]`. The runner grabs them the moment
it registers, which would race the manual converge
([onboarding-reference-manager.md §4](onboarding-reference-manager.md)). Then converge by hand:

```bash
slot() { ssh krg-admin@krg-nat.ucsd.edu "incus exec e4e-website --project e4e-website --env PATH=/run/current-system/sw/bin -- $*"; }
slot nixos-rebuild switch --flake github:UCSD-E4E/website2.0#e4e-website --refresh
slot systemctl show openbao-agent.service github-runner-e4e-website.service -p Id -p Result -p ActiveState
```

## 4. Verify

- `slot ls -l /run/tenant/secrets/mywebsite_ed25519` → `-r-------- root`. Never `cat` it.
- Dry-run the transport from the slot as the publish user (no write):
  `slot systemd-run --wait --pipe -p User=e4e-website-publish -p LoadCredential=key:/run/tenant/secrets/mywebsite_ed25519 sh -c 'ssh -i $CREDENTIALS_DIRECTORY/key -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/mywebsite_known_hosts e4e@mywebsite.eng.ucsd.edu "command -v rsync"'`
  → a path. (`publish.nix` uses rsync-over-ssh rather than the old sshfs, so the remote
  needs `rsync`. If this prints nothing, raise it with ETS or switch publish.nix to sftp.)
- Re-run the latest `Deploy Jekyll site` on main (workflow_dispatch). `deploy` goes
  green, its "Publish log" step shows rsync `--stats`, and
  `curl -s https://e4e.ucsd.edu/last_deployed.txt` shows that run's commit.

## Notes

- **Host key pinned** in `publish.nix` (`/etc/ssh/mywebsite_known_hosts`, ed25519,
  collected 2026-10-15). If ETS rebuilds mywebsite, publishing fails closed with a
  host-key error. Re-collect it from campus and update the website repo.
- **`--delete` safety**: publishes serialize (main runs queue rather than cancel, the
  deploy job waits out an in-flight publish, and the runner can't stop or restart the
  unit). The runner only renames a *complete* download into `staging/site`, and the
  unit refuses unless `index.html` and the build's `last_deployed.txt` are both there,
  so an empty or partial upload can't wipe htdocs.
- **No compose, no Docker.** `nixosModules.tenant` now enables Docker only for compose
  tenants, and switches the vault-agent on whenever any render is declared (it used
  to be compose-only, which would have silently dropped this slot's key render).
- **Losing `terraform/secrets` state** for the key can't be fixed by `TOFU_IMPORT`
  (`tls_private_key` isn't importable). Rotate with `TOFU_SECRETS_APPROVE` and redo
  gate 3 (see the comment in `e4e_website.tf`).
- **Not in Grafana.** A blackbox probe of `https://e4e.ucsd.edu/` is a cheap follow-up.
