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
| `deploy-nixos.sh` | krg-vault, krg-ldap, krg-prod, waiter | `--build-host = --target-host` so each host builds its own closure (krg-deploy only evaluates). **krg-deploy itself is excluded** from the rebuild — it runs the job; it stays current via nightly `autoUpgrade` (and self-verifies OEC locally — see *OEC* below). **e4e-prod is omitted** until the host is provisioned. **Stages the OEC installer to each host before the switch and verifies both security daemons are active afterwards** (see *OEC* below). |
| `deploy-ansible.sh` | `ansible/playbooks/site.yml` (Proxmox) | Synology is **opt-in** (`DEPLOY_SYNOLOGY=true`, off by default) — its declarative sync deletes, and bring-up has gates (see [docs/e4e-nas-dsm.md](../docs/e4e-nas-dsm.md)). Galaxy collections (`ansible/requirements.yml`) must be **provisioned on the control node** (not installed per-run — matches the nightly `ansible-apply`); deterministic/Nix-managed collections tracked in #129. **Passes `oec_installer` so the Proxmox hosts enroll + verify the OEC daemons too** (see *OEC* below). |
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

## Rebooting the fleet (manual)

`reboot-fleet.sh` + the **Reboot fleet** workflow
([`.github/workflows/reboot-fleet.yml`](../.github/workflows/reboot-fleet.yml)) are a
push-button reboot, run on the same krg-deploy runner with the same fleet identity.
It's **`workflow_dispatch`-only** (a reboot is never an automatic consequence of a
commit) and shares the `deploy-fleet` concurrency group so it can't overlap a deploy.
It reboots each host sequentially — issuing the reboot, then confirming the box came
back by watching the kernel `boot_id` change — and is **fail-fast**: if a host
doesn't return, the rest are left alone. An optional input restricts it to a subset
(e.g. `waiter`). Targets the provisioned NixOS hosts (mirrors `deploy-nixos.sh`) plus
the **e4e-nas** Synology appliance. **`krg-deploy` and `fabricant` are excluded for
now** (the runner can't reboot itself; the hypervisor would drop every guest) —
tracked in [#181](https://github.com/KastnerRG/krg-infra/issues/181).

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
- `/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz` — the
  campus-mandated **OEC** (Qualys + Trellix) vendor archive, holding live enrollment
  creds (gitignored). Both deploy scripts **fail if it's absent** (`OEC_INSTALLER`
  overrides the path) — see *OEC* below.

## OEC (campus-mandated Qualys + Trellix) — enforced

The Qualys Cloud Agent + Trellix HX (xagt) endpoint agents are **mandatory on every
host** ([#22](https://github.com/KastnerRG/krg-infra/issues/22)), so the deploy treats
them as a hard gate rather than best-effort:

- **NixOS** (`deploy-nixos.sh`): `scp`s the archive to each host's runtime path
  (`/var/lib/krg/oec/…`) **before** `nixos-rebuild switch` — so that switch's
  `oec-install` oneshot ([`modules/security/oec-qualys-trellix.nix`](../nix/modules/security/oec-qualys-trellix.nix))
  enrolls on the same run — then, after the whole fleet has rebuilt, checks
  `qualys-cloud-agent` + `xagt` are `active` on every host.
- **krg-deploy itself** (the control node) is excluded from the rebuild loop — a
  self-`switch` would restart the running github-runner mid-job — so it enrolls via
  its nightly `autoUpgrade` instead, pointed at the archive it already holds in
  `.secrets/` ([`nix/hosts/krg-deploy`](../nix/hosts/krg-deploy/default.nix) sets
  `krg.oecQualysTrellix.installerArchive`). `deploy-nixos.sh` still verifies it,
  **locally** (no ssh/rebuild), folded into the same gate.
- **Proxmox** (`deploy-ansible.sh`): passes `oec_installer`; the
  [`oec_qualys_trellix`](../ansible/roles/oec_qualys_trellix) role copies + installs
  the archive and asserts both daemons are active.
- **A missing archive on the control node, or any host where either daemon is not
  active, fails the deploy** — no silently-unhardened machine. (The Ansible role
  still no-ops gracefully when `oec_installer` is unset, so `--check`/local runs are
  unaffected; enforcement lives in the CD path.)
- **Bring-up note:** issue #22 had the nix-ld path validated only on krg-ldap. With
  this gate, deploys now fail until the agents come up on krg-prod / e4e-prod / waiter
  too — that's the intended forcing function, but expect the first push after staging
  the archive to surface any remaining per-host nix-ld/library gaps.

## Tunables (env)

`DEPLOY_ADMIN` (`krg-admin`) · `DEPLOY_SSH_KEY` · `DEPLOY_SSH_ACCEPT_NEW` (`false`) ·
`DEPLOY_SYNOLOGY` (`false`) · `OEC_INSTALLER`
(`/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz`) ·
`TOFU_TARGETS` (`openbao authentik grafana e4e-nas`) ·
`TOFU_STATE_ROOT` (`/var/lib/krg-admin/tofu-state`).
