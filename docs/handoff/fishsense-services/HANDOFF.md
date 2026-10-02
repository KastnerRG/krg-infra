# fishsense-services (v2) on the fishsense slot: cutover hand-off

FishSense tenant `fishsense` moves from repo **UCSD-E4E/fishsense-lite** (v1) to
**UCSD-E4E/fishsense-services** (v2) **on the same Incus slot**, the weekend of
**2026-10-10/11**, with a **48-hour rollback window**. This doc is the platform's
half: what the platform owns, what the tenant owns, the admin's exact procedure,
and what to retire afterwards. The tenant's full runbook, the source of truth
for everything inside the slot, is fishsense-services
[`docs/cutover.md`](https://github.com/UCSD-E4E/fishsense-services/blob/main/docs/cutover.md).
Section numbers like "§3 step 4" below refer to that file.

The v1 hand-off ([`../fishsense-lite/HANDOFF.md`](../fishsense-lite/HANDOFF.md))
still describes the ingress chain, Temporal access and secret delivery, all
unchanged. Read it for those.

---

## 0. Open items before the switch (check each)

| # | Item | Owner | Status |
|---|---|---|---|
| B1 | **v2's workers couldn't read the Temporal key or the NRP kubeconfig.** `orchestrator`, `backup`, `nrp-temporal-cert-sync` and `smoke` run as uid 10001 (`USER app` in the published `v0.1.0` images). The platform renders `/run/tenant/temporal/tls.key` **0640 root:root**, and v2's own render puts `/run/tenant/nrp/` at 0750 with `kubeconfig` 0640 root:root. Bind mounts keep host ownership, so uid 10001 got `EACCES`. The owner reproduced it on v0.1.0. **Fixed in fishsense-services #22:** `group_add: ["0"]` on those four services (root's group only, not root), pinned by a deploy test. The fix needs no new release, because the slot reads the compose from `main`. A platform-side gid option is a follow-up (§6). | FishSense owner | ✅ fixed (#22) |
| B2 | **The `nrp_orchestrator` path must exist in OpenBao**, even if the kubeconfig isn't ready. `errorOnMissingKey = false` softens a missing **field** only. A missing **path** is a hard `no secret exists at …` error in openbao-template, and with `exit_on_retry_failure` it fails the whole agent: every render, the `fishsense.vm` cert, and so the entire stack. If the kubeconfig isn't ready, seed `bao kv put secret/tenants/fishsense/nrp_orchestrator kubeconfig=""`. v2 treats an empty kubeconfig as "no NRP yet" (fishsense-services #22 runbook). | FishSense owner | before switch |
| B3 | **GitHub App installed on fishsense-services**: add the repo to the org installation's *selected repositories*. The installation is the same, so `secret/krg-deploy/github-app/UCSD-E4E` doesn't change. Without it, phase 3.6 warns and mints nothing, and the slot has no runner after the switch. | admin | before switch |
| B4 | **#550 must be APPLIED before the switch.** Since fishsense-services #22, v2's `web.env` reads `secret/tenants/fishsense/oidc/web-service-account` directly. That's a hard render, so if #550 hasn't run, the path is missing and the whole agent fails (as in B2). Nothing to copy (§3). | admin | before switch |
| — | **Superset goes dark at the switch, not at §3 step 5c.** `fishsense.service` changes on the switch, so `switch-to-configuration` **stops** the old unit first, and its `ExecStop` is v1's `docker compose … down`. That removes v1's Superset along with everything else. `analytics.fishsense` answers 502 until v2's Superset profile is turned on. The owner accepts this (consistent with sunsetting v1), and the runbook is corrected in #22. | FishSense owner | ✅ accepted |

Already confirmed (no action):

- **Images:** all six `ghcr.io/ucsd-e4e/fishsense-services-*` packages pull anonymously and `:v0.1.0` resolves. The compose pins `v0.1.0` (no `v0.0.0`).
- **Repo:** fishsense-services is public, so selfupdate and autoUpgrade fetch it anonymously.
- **krg-infra pin:** fishsense-lite and fishsense-services both lock `ec7e4b607fc5faacdc1439d7e4dec631d072e632`. Their `mkTenant` calls differ only in `repo` and `temporal.reload`, so `terraformTenant` is identical.

---

## 1. Who owns what

| | Platform (krg-infra, admin) | Tenant (fishsense-services, FishSense owner) |
|---|---|---|
| Slot, project, quota, image, `nat_ip` 10.100.0.10, edge `:30443`, e4e edge route | `terraform/incus`, `nix/hosts/e4e-prod`: **unchanged** | — |
| Runner repo scope (the broker) | `terraform/incus` `tenants.fishsense.repo` → `user.krg_repo` (**#549**) | `mkTenant { repo = …; }` (the runner's `url`) |
| Runner token push | CD phase 3.6 `deploy/stage-tenant-secret-zero.sh` | — |
| `fishsense-selfupdate`, nightly `system.autoUpgrade` | `nixosModules.tenant`; both derive from mkTenant's `repo` | the flake those units build |
| OpenBao AppRole + policy `tenant-fishsense` | `terraform/openbao` `tenants.tf`: **prefix grant, unchanged** | the values under `secret/tenants/fishsense/*` |
| `oidc/web`, `oidc/analytics`, `oidc/web-service-account` | `terraform/authentik` (**#550**) | read directly by v2's renders |
| `services_db`, `nrp_orchestrator`, `model_weights` | — | seeded by the owner (cutover.md §1.3) |
| Interior: compose, `secrets.nix`, `workdir.nix`, `prune.nix`, `cert-sync-timer.nix` | — | all of it |
| Temporal namespace `fishsense`, client cert CN `fishsense-worker` | `terraform/temporal`, `terraform/openbao`: **unchanged** | `temporal.reload` list |
| Lab memberships (who sees what in v2) | — | rows in v2's DB keyed on OIDC `sub` (§3 step 4d) |

---

## 2. What the platform checked against v2

### Runner and selfupdate (ask 1)

- **Where the broker scopes repos.** There is no allowlist. `deploy/stage-tenant-secret-zero.sh` reads each instance's `user.krg_repo`. `terraform/incus/instances.tf` stamps it from `var.tenants.<name>.repo`. The script then asks `mint-runner-token.sh --is-registered <repo> <name>` and, if the runner isn't registered **on that repo**, mints and pushes a fresh token. **#549** flips `fishsense` to `UCSD-E4E/fishsense-services`. It's an in-place `config` update: lxc/incus 1.1.1 forces replacement only on `image`, `type` and `project`, so the VM is not recreated.
- **Changing a tenant's repo without a gap.** The nixpkgs github-runner diffs its config (including `url`) and the token-file bytes on every start. On the first switch the `url` changes, so it wipes its state and runs `config.sh --replace` with whatever token is in `/var/lib/krg/github-runner/registration-token`. If that token is older than ~1 h it fails. The unit then sits in `activating (auto-restart)`, which doesn't fail the switch (`nix/modules/tenant.nix`), and retries every 30 s, **re-reading the token file on each retry**. So the gap is "until a fresh token is pushed". Close it by running phase 3.6 by hand just before the switch (§4 step 2), and again if the runner isn't online two minutes after the switch.
  - Merging #549 early is fine (fishsense-lite may break). From the next deploy, phase 3.6 pushes fishsense-services tokens. v1's runner keeps its registration until it next restarts, which is v1's next selfupdate. It then wipes its state and can't re-register (wrong repo), so **v1's auto-deploy is dead from then on**. v1's nightly autoUpgrade is unaffected.
- **selfupdate and autoUpgrade follow `repo`.** Evaluated from fishsense-services at its lock:
  - `system.autoUpgrade.flake` = `github:UCSD-E4E/fishsense-services#fishsense` (`base.nix`: `flake = "${flakeUrl}#${hostName}"`, `tenant.nix`: `flakeUrl = "github:${repo}"`).
  - `fishsense-selfupdate` runs `nixos-rebuild switch --flake github:UCSD-E4E/fishsense-services#fishsense --refresh`.
  - `services.github-runners.fishsense.url` = `https://github.com/UCSD-E4E/fishsense-services`, with `replace = true`.

  All three are baked in at build time, so they move to v2 with the first switch and nothing else. Until then the slot keeps building fishsense-lite. That's why the first switch is by hand.

### OpenBao policy (ask 4)

`terraform/openbao/tenants.tf` grants `secret/data/tenants/fishsense/*` (read) and `secret/metadata/tenants/fishsense/*` (read, list) **by prefix**. `services_db`, `web_service_account`, `nrp_orchestrator` and `model_weights` are all covered. **No change.**

### Authentik (ask 3), #550

| Ask | Finding | Change |
|---|---|---|
| `refresh_token` grant | `grant_types` not set in tofu | explicit `authorization_code, refresh_token, client_credentials` |
| `offline_access` | not mapped | + managed `scope-offline_access` |
| `groups` | mapped (#521) | — |
| `org` | **exists**: `fishsense_org` in `fishsense_collaborators.tf` emits `{tenant, org}` from user attributes (set by the collaborator enrollment flow; null for lab AD members, whom v2 treats as lab) and is already mapped on the web client | — |
| Redirect URI | `https://fishsense.e4e.ucsd.edu/api/auth/callback/authentik` | unchanged |
| **Signing key** (not in the ask) | **none**, so HS256 with an empty JWKS. v2's API accepts **RS256 only** (`auth.py` `ALGORITHMS`), so every API call would 401. | `signing_key` = default cert |
| Web service account | none | `svc-fishsense-web`, native `service_account`, app password, user binding on the web app, written to `secret/tenants/fishsense/oidc/web-service-account {username, password}` |

### Tenant module compatibility (ask 5)

Evaluated from fishsense-services' `nixosConfigurations.fishsense` at krg-infra `ec7e4b6`:

| Check | Result |
|---|---|
| Reload list names v2 services | `docker compose --project-directory /var/lib/krg/fishsense -f …/deploy/incus/compose.yml restart orchestrator backup nrp-temporal-cert-sync`. All three exist in v2's compose. `restart` also starts the exited `restart: "no"` cert sync, which is what v2 wants. |
| Several env renders under `/run/tenant/secrets/` | 9 renders. The parent dir is created once (`install -d -m 0750`) and the files are 0640 root. Compose reads `env_file` as root, so this works. |
| Fail-closed, `nrp_orchestrator` soft | Every app render has `errorOnMissingKey = true`, and `/run/tenant/nrp/kubeconfig` has it `false`. **Soft covers a missing field only, not a missing path** (B2). |
| Project directory | `/var/lib/krg/fishsense`. There's no top-level `name:` in the compose, so the project stays `fishsense` and `pgdata` is v1's `fishsense_pgdata`. |
| `up -d --remove-orphans --force-recreate` | Yes. `ExecStart` carries both (`recreateOnConfigChange = true`, the #458 fix). |
| `superset` profile off | `compose.env` → `/var/lib/krg/fishsense/.env` with `COMPOSE_PROFILES=` (empty), which the stack and the reload hook both read via `--project-directory`. The platform passes no `--profile` or `--env-file`. Superset stays off, but see the "goes dark at the switch" note in §0. |
| Container uid vs render perms | **B1**: the platform renders assumed a root consumer. Fixed tenant-side (`group_add: ["0"]`, fishsense-services #22). |

**Platform changes needed for the cutover:** none in `nixosModules.tenant`. The changes are the runner scope (#549), Authentik (#550), and the corrected `errorOnMissingKey` description (this PR). B1 was fixed on the tenant side (fishsense-services #22).

---

## 3. The web service account (B4)

After #550 applies, the account's credential is in OpenBao at
`secret/tenants/fishsense/oidc/web-service-account` (`username`, `password`).
Since fishsense-services #22, v2's `web.env` render reads that path directly, so
nothing is copied, and a rotation is a tofu re-apply plus a re-render. The old
owner-seeded `web_service_account` path is no longer read.

The account's **`sub`** (needed for its lab membership, §3 step 4d). This prints
the `sub` claim only, never the token:

```bash
S=$(bao kv get -format=json secret/tenants/fishsense/oidc/web-service-account)
W=$(bao kv get -format=json secret/tenants/fishsense/oidc/web)
curl -s https://auth.krg.ucsd.edu/application/o/token/ \
  -d grant_type=client_credentials -d scope=openid \
  -d client_id="$(jq -r .data.data.client_id <<<"$W")" \
  -d client_secret="$(jq -r .data.data.client_secret <<<"$W")" \
  -d username="$(jq -r .data.data.username <<<"$S")" \
  -d password="$(jq -r .data.data.password <<<"$S")" \
  | jq -r .access_token | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r .sub
unset S W
```

The same call is the end-to-end test of the grant: a non-null `sub` means the
grant type, the app password and the user binding all work.

---

## 4. Admin procedure

`slot` is cutover.md's helper:
`slot() { ssh krg-admin@krg-nat.ucsd.edu "incus exec fishsense --project fishsense -- $*"; }`

### Before the weekend

1. **Install the GitHub App on fishsense-services** (B3). Then, on krg-deploy, from a krg-infra checkout as `krg-admin`:
   ```bash
   ./deploy/mint-runner-token.sh --is-registered UCSD-E4E/fishsense-services fishsense; echo "rc=$?"
   ```
   Expect `runner 'fishsense' is NOT registered at UCSD-E4E/fishsense-services` with `rc=1`. `could not list runners` means the App can't see the repo yet.
2. **Merge #549 (runner scope) and #550 (Authentik).** Then check the `Deploy fleet` run. It must be a real deploy, not the ~9 s "skipping deploy" success.
   - The tofu `incus` plan must show `incus_instance.tenant["fishsense"]` **updated in-place**, `config` only.
   - The `authentik` plan: 1 in-place update, 4 creates.
   - Phase 3.6 must print `staged runner token for fishsense (repo UCSD-E4E/fishsense-services)`.
3. **Confirm OpenBao is seeded** (B2, B4). Keys only, no values:
   ```bash
   for p in postgres superset web label_studio object_store nas services_db \
            nrp_orchestrator model_weights oidc/web oidc/analytics oidc/web-service-account; do
     printf '%s: ' "$p"; bao kv get -format=json "secret/tenants/fishsense/$p" | jq -c '.data.data | keys'
   done
   ```
   Every line must print keys. An error on any path rendered on the slot fails the whole agent: `nrp_orchestrator` counts (B2), and so does `oidc/web-service-account`, which exists only once #550 has applied (B4).
4. **Confirm B1 is still fixed** on fishsense-services `main` (merged in #22):
   ```bash
   gh api repos/UCSD-E4E/fishsense-services/contents/deploy/incus/compose.yml --jq .content | base64 -d | grep -c 'group_add'
   ```
   Expect 4 (orchestrator, backup, nrp-temporal-cert-sync, smoke).
5. **Freeze the flake bumps** (ask 7): both repos' weekly `update-flake.yml` runs Mondays 08:00 UTC. Pause both through the rollback window, then check the locks still match:
   ```bash
   gh workflow disable update-flake.yml -R UCSD-E4E/fishsense-lite
   gh workflow disable update-flake.yml -R UCSD-E4E/fishsense-services
   for r in fishsense-lite fishsense-services; do
     gh api "repos/UCSD-E4E/$r/contents/flake.lock" --jq .content | base64 -d | jq -r '.nodes["krg-infra"].locked.rev'
   done   # both must print the same rev
   ```
   krg-infra's own nightly `flake update` doesn't matter here. Tenants build from their own lock.

### Friday T-0 (cutover.md §2)

The owner pauses schedules and stops v1's writers. Admin:
`slot systemctl stop nixos-upgrade.timer`.

### The switch (cutover.md §3 step 4a)

1. **Pre-flight build** (evaluates and fetches everything, touches nothing running):
   ```bash
   slot nixos-rebuild build --flake github:UCSD-E4E/fishsense-services#fishsense --refresh
   ```
2. **Push a fresh runner token** (closes the registration gap). On krg-deploy, from the krg-infra checkout:
   ```bash
   ./deploy/stage-tenant-secret-zero.sh
   ```
   Expect `staged runner token for fishsense (repo UCSD-E4E/fishsense-services)`. The token lives ~1 h, so switch within the hour.
3. **Switch:**
   ```bash
   slot nixos-rebuild switch --flake github:UCSD-E4E/fishsense-services#fishsense --refresh
   ```
   Exit 4 from `switch-to-configuration` is **not** the signal. Check the units:
   ```bash
   slot systemctl show openbao-agent.service fishsense.service -p Id -p Result   # both success
   slot docker ps -a --format '{{.Names}} {{.Status}}'                          # db-bootstrap, migrate: Exited (0)
   ```
   If `openbao-agent` failed: `slot journalctl -u openbao-agent -n 50`. A `no secret exists at …` names the missing path (B2): seed it, then `slot systemctl restart openbao-agent fishsense`.
4. **The runner re-registered** on fishsense-services:
   ```bash
   slot journalctl -u github-runner-fishsense -n 30 --no-pager      # "Config has changed" → "Runner successfully added"
   gh api repos/UCSD-E4E/fishsense-services/actions/runners \
     --jq '.runners[] | {name, status, labels: [.labels[].name]}'    # fishsense, online, [self-hosted, …, fishsense]
   ```
   If it's still in `auto-restart` with a token error, run step 2 again. The next retry, within 30 s, picks up the new token.
5. **The repo moved everywhere:**
   ```bash
   slot systemctl cat fishsense-selfupdate.service | grep -o 'github:[^ ]*'   # …fishsense-services#fishsense
   slot systemctl cat nixos-upgrade.service | grep -o 'github:[^ ]*'         # …fishsense-services#fishsense
   ```
   The switch re-enabled `nixos-upgrade.timer` with v2's definition. cutover.md §3 step 4b stops it again; the owner does that.

The owner then runs §3 steps 4b to 7. From here the owner's own `Deploy` workflow (`workflow_dispatch` → `incus`) runs on this runner.

### Rollback (within 48 h of reopening, cutover.md §6)

1. The owner pauses and deletes v2's schedules.
2. Admin:
   ```bash
   slot nixos-rebuild switch --flake github:UCSD-E4E/fishsense-lite#fishsense --refresh
   # or, offline: slot nixos-rebuild switch --rollback   (the previous generation is v1's)
   ```
   The old unit's `ExecStop` is v2's `down`, then v1's `up` on the same `pgdata`. Check `slot systemctl show openbao-agent.service fishsense.service -p Result` as above. v1's renders only read paths that still exist (`api`, `nrp`, `oidc/proxy-outpost-token` are kept through the window).
3. **Runner:** revert #549. The next deploy's phase 3.6 mints for fishsense-lite again, and v1's runner (now `url = fishsense-lite`) re-registers. Until then v1 has no auto-deploy runner, which is fine for a rollback. The admin converges by hand as above.
4. Authentik: nothing to undo. #550 keeps everything v1 uses, and the forwardAuth outpost still exists.

---

## 5. After the rollback window closes (48 h after reopening)

Platform (krg-infra), in the **draft** retirement PR. Merge it only once the owner confirms "no rollback":

- `authentik_provider_proxy.fishsense_orchestrator`, `authentik_application.fishsense_orchestrator` and its `app_access` + collaborator bindings
- `authentik_outpost.fishsense_proxy`, its API token, and `secret/tenants/fishsense/oidc/proxy-outpost-token`
- the NRP data-worker app password on `svc_fishsense` (`fishsense_data_worker.tf`) and `oidc/data-worker-apppw`. It existed only to pass that proxy (#483), and v1's data-worker is retired.

By hand / other repos:

- Owner: delete v1-only KV paths `api` and `nrp` (`bao kv metadata delete …`), and archive fishsense-lite.
- Admin: remove the stale offline runner `fishsense` from fishsense-lite (Settings → Actions → Runners).
- Admin: **re-enable** `update-flake.yml` on fishsense-services only:
  `gh workflow enable update-flake.yml -R UCSD-E4E/fishsense-services`.
  Skip it and the slot freezes on old packages (docs/tenant-updates.md).
- Keep `svc_fishsense` itself: it's a KRG.LOCAL principal with other domain access.

## 6. Platform follow-ups (not cutover-blocking)

- **Non-root readers of platform renders (B1, done properly):** let a tenant name the gid its Temporal consumers run as (e.g. `mkTenant { temporal.readerGid = 10001; }`). `nixosModules.tenant` would then deliver `tls.key` as `0640 root:<gid>`. The OpenBao Agent docs don't expose a template `group` setting, so this is likely a post-render `chgrp`, ordered before the reload hook. It's an additive contract change, so it needs a tenant pin bump. Too late for this weekend.
- `deploy/mint-runner-token.sh` points to `docs/tenant-runner-bringup.md` §4, which doesn't exist.
- Rotation of the non-expiring app passwords (`svc-fishsense-web`, and the outpost/data-worker ones until retired).
