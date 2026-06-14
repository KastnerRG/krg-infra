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
deploy/deploy-tofu.sh    tofu apply per target  (active; creds from OpenBao, opt-in via TOFU_TARGETS)
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
| `deploy-tofu.sh` | the targets named in `TOFU_TARGETS` | **Active; creds from OpenBao, no secrets on disk.** krg-deploy logs into OpenBao with its AppRole (the same `openbao-role-id`/`openbao-secret-id` the Ansible leg uses) and reads each target's creds from KV at apply time (paths below). **Opt-in:** only targets listed in `TOFU_TARGETS` apply (empty by default — like `SYNOLOGY_TAGS` scopes the synology converge); a listed target whose KV secret isn't seeded **skips** with a notice. A ready target with no `TOFU_STATE_PASSPHRASE` **hard-fails** rather than writing plaintext state (ADR 0005). State persists under `TOFU_STATE_ROOT` (CI checkout is ephemeral), always encrypted. **`openbao` is special** — it provisions OpenBao's own auth, so it can't use that AppRole; apply it manually with a privileged `TOFU_OPENBAO_TOKEN` (see below). |

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
doesn't return, the rest are left alone. An optional comma-separated `hosts` input
restricts it to a subset (e.g. `waiter,krg-prod`). Targets the provisioned NixOS
hosts (mirrors `deploy-nixos.sh`) plus
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
- `/var/lib/krg-admin/.secrets/openbao-role-id` + `openbao-secret-id` — krg-deploy's
  OpenBao AppRole, **shared with the Ansible leg** (already provisioned for it). The
  tofu leg reuses it: no tofu-specific secret files. Every target's creds are read
  from OpenBao KV at apply time (see *OpenTofu* below for the paths).
- `TOFU_STATE_PASSPHRASE` — repo Actions secret; encrypts OpenTofu state.
  **Required before any target applies** — a ready target with no passphrase
  hard-fails (ADR 0005: state holds live secrets, must not be written in the clear).
  Set it once with `gh secret set TOFU_STATE_PASSPHRASE`.
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

## OpenTofu — creds from OpenBao (no secrets on disk)

`deploy-tofu.sh` reuses the **same OpenBao AppRole as the Ansible leg**
(`openbao-role-id` / `openbao-secret-id` in `.secrets/`) — there is no
tofu-specific secrets file. It logs in, exports `VAULT_ADDR`/`VAULT_TOKEN`, and
reads each target's creds from KV at apply time. Seed these once with `bao kv put`
(part of the OpenBao secrets epic, [#112](https://github.com/KastnerRG/krg-infra/issues/112)):

| Target | KV path → field | Used as |
|---|---|---|
| `grafana` | *(none — reads `secret/krg-prod/grafana-admin` + `grafana-oidc` in-config via the vault provider)* | `VAULT_TOKEN` only |
| `authentik` | `secret/krg-deploy/authentik-admin-token` → `token` | `TF_VAR_authentik_token` |
| `authentik` | `secret/krg-deploy/authentik-bind` → `password` | `TF_VAR_ldap_bind_password` |
| `e4e-nas` | `secret/e4e-nas/users` → `<dsm_user>` (default `e4e-automation`) | `TF_VAR_dsm_password` |
| `e4e-nas` | `secret/e4e-nas/dsm-otp` → `secret` *(optional)* | `TF_VAR_dsm_otp_secret` |

The krg-deploy AppRole policy grants read on `secret/krg-deploy/*` and
`secret/e4e-nas/*`, read on `secret/krg-prod/grafana-admin`, and full lifecycle
(create/update/read/delete) on the OIDC + roster paths the `authentik` target
writes back — `secret/krg-prod/{grafana,outline,mlflow,roster,vaultwarden,guacamole}-oidc`,
`secret/krg-prod/{roster,roster-ldap,guacamole}`, and `secret/e4e-nas/{garage-ui,dsm-sso}-oidc`
(`local.authentik_managed_secrets` in `terraform/openbao/main.tf`). It is
**enumerated, not `secret/krg-prod/*`** (#187 least-privilege), so adding a new
`vault_kv_secret_v2` in `terraform/authentik/` requires adding its path to that
local, or the apply 403s. `grafana` reads `grafana-oidc` from this same set, so it
applies only after `authentik` has run at least once to populate it (hence
authentik-before-grafana in `TOFU_TARGETS`). `e4e-nas` works against the policy too.

**`openbao` target** provisions OpenBao's own mount/auth/policies, so it can't
authenticate with the AppRole it's creating. Apply it manually with a privileged
token (root or an admin token), not via the push-CD:

```bash
TOFU_TARGETS=openbao TOFU_OPENBAO_TOKEN="<privileged token>" \
  TOFU_STATE_PASSPHRASE="<same as the Actions secret>" ./deploy/deploy-tofu.sh
```

## Tunables (env)

`DEPLOY_ADMIN` (`krg-admin`) · `DEPLOY_SSH_KEY` · `DEPLOY_SSH_ACCEPT_NEW` (`false`) ·
`DEPLOY_SYNOLOGY` (`false`) · `OEC_INSTALLER`
(`/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz`) ·
`TOFU_TARGETS` (empty — explicit opt-in) · `TOFU_OPENBAO_TOKEN` (openbao bootstrap) ·
`TOFU_STATE_ROOT` (`/var/lib/krg-admin/tofu-state`) · `VAULT_ADDR`
(`https://krg-vault.ucsd.edu:8200`) · `OPENBAO_ROLE_ID_FILE` / `OPENBAO_SECRET_ID_FILE`.
