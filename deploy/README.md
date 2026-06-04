# deploy/ — push-to-main continuous deploy

`git` is the single source of truth ([ADR 0001](../docs/adr/0001-iac-source-of-truth.md)).
These scripts apply `main` to the live fleet from the **control node, krg-deploy**
([ADR 0005](../docs/adr/0005-repo-integration-opentofu-krg-deploy.md)) — turning the
pull-based nightly apply (NixOS `system.autoUpgrade` + the krg-deploy `ansible-apply`
timer) into a **push-triggered** apply.

## How it fits together

```
push to main
   │  (build.yml: nix flake check + per-host builds)   ─┐
   │  (tests.yml: pytest helpers + drift detector)     ─┤ BOTH must be green
   ▼                                                    │
.github/workflows/deploy.yml  ──(workflow_run, gated)───┘
   │   runs-on [self-hosted, krg-deploy]
   ▼
deploy/deploy-nixos.sh   nixos-rebuild switch --target-host (each host builds itself)
deploy/deploy-ansible.sh ansible-playbook site.yml  (Synology opt-in)
deploy/deploy-tofu.sh    tofu apply per target  (DEFERRED — step commented out in deploy.yml)
```

The runner itself is declarative — `services.github-runners.krg-deploy` in
[`nix/hosts/krg-deploy/default.nix`](../nix/hosts/krg-deploy/default.nix). It runs
as `krg-admin`, reusing the control node's existing fleet identity (SSH keys +
`sudoNoPassword` on every host, the same identity the nightly `ansible-apply` timer
uses).

## What each script does

| Script | Applies | Notes |
|---|---|---|
| `deploy-nixos.sh` | krg-vault, krg-ldap, krg-prod, waiter | `--build-host = --target-host` so each host builds its own closure (krg-deploy only evaluates). **krg-deploy itself is excluded** — it runs the job; it stays current via nightly `autoUpgrade`. **e4e-prod is omitted** until the host is provisioned. |
| `deploy-ansible.sh` | `ansible/playbooks/site.yml` (Proxmox) | Synology is **opt-in** (`DEPLOY_SYNOLOGY=true`, off by default) — its declarative sync deletes, and bring-up has gates (see [docs/e4e-nas-dsm.md](../docs/e4e-nas-dsm.md)). |
| `deploy-tofu.sh` | each `terraform/<target>/` with a `.deploy-env` | **Deferred** — the step is commented out in `deploy.yml`. Script is in place and dormant. State persists under `TOFU_STATE_ROOT` (CI checkout is ephemeral); encrypted when `TOFU_STATE_PASSPHRASE` is set. |

The scripts run by hand on krg-deploy too (they only need the deploy toolchain + the
secrets below) — `./deploy/deploy-nixos.sh`, etc.

## Gating

`deploy.yml` never runs on `push` directly. It triggers on `workflow_run` after the
two CI workflows complete on `main`, and re-checks that **both** succeeded for the
same commit before applying — so a broken commit never deploys. A single deploy runs
at a time (`concurrency: deploy-fleet`).

**Fail-fast, end to end.** Each script stops on the first failed host/target (it
doesn't push on to the rest), and each workflow stage gates the next (`success() &&
…`), so a failed NixOS apply skips the Ansible (and OpenTofu) stage rather than
deploying on top of a half-broken fleet.

## Secrets (NOT in git — operator-provisioned)

- `/var/lib/krg-admin/.secrets/github-runner-token` — runner registration token / PAT
  (repo *Administration* scope). Used to register the runner. **Bring-up:** a short-lived
  registration token for now; move to a lab-owned bot-account PAT in OpenBao — see #121.
- `/var/lib/krg-admin/.ssh/id_ed25519` — krg-admin's key to the fleet (already needed
  by `ansible-apply`).
- `/var/lib/krg-admin/.ssh/known_hosts` — the fleet's host keys. Host-key checking is
  **strict** by default (NixOS via `StrictHostKeyChecking=yes`, Ansible via
  `ansible.cfg host_key_checking=True`), so this must be provisioned out-of-band. For
  first-time bring-up only, set `DEPLOY_SSH_ACCEPT_NEW=true` to trust-on-first-use.
- `terraform/<target>/.deploy-env` — sourced per target to export `VAULT_TOKEN`,
  `TF_VAR_*`, etc. Targets without it are **skipped** (safe to land before creds exist).
- `TOFU_STATE_PASSPHRASE` — repo Actions secret; encrypts OpenTofu state.

## Tunables (env)

`DEPLOY_ADMIN` (`krg-admin`) · `DEPLOY_SSH_KEY` · `DEPLOY_SSH_ACCEPT_NEW` (`false`) ·
`DEPLOY_SYNOLOGY` (`false`) · `TOFU_TARGETS` (`openbao authentik grafana e4e-nas`) ·
`TOFU_STATE_ROOT` (`/var/lib/krg-admin/tofu-state`).
