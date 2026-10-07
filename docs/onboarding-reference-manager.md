# Onboarding reference-manager: the first krg-zone Incus tenant

The E4E reference manager ([UCSD-E4E/e4e-reference-manager](https://github.com/UCSD-E4E/e4e-reference-manager),
FastAPI `api/` + Vite/React PWA `web/`) runs as Incus tenant **`reference-manager`** at
**https://bib.krg.ucsd.edu**. It is a slot exactly like fishsense
([onboarding-fishsense.md](onboarding-fishsense.md), ADR 0017 / 0020). The one new piece
is the zone: `bib.krg.ucsd.edu` is a **krg** name, so the **krg-prod** edge fronts it.
fishsense is fronted by e4e-prod. This is the first route on the krg edge.

This runbook is the admin's half. The tenant's half (the files that go into the app
repo, and the app changes) is [handoff/reference-manager/HANDOFF.md](handoff/reference-manager/HANDOFF.md).

## The shape

```
browser ─https─▶ bib.krg.ucsd.edu (CNAME → krg-prod)
                 krg-prod compose Traefik: LE cert, router from krg.edge (provider "file")
                 └─re-encrypt, verify reference-manager.vm vs the fleet CA─▶ krg-nat:30444
                   └─incus_network_forward─▶ 10.100.0.11:443  (slot's inner Traefik)
                       /api/*  → api:8000  (prefix stripped; uvicorn --root-path /api)
                       /*      → web:8080  (static PWA, SPA fallback)
browser ─https─▶ s3.e4e.ucsd.edu (e4e-nas Garage) — presigned path-style GETs for PDFs
```

Inside the slot: api, web, postgres (pgvector), translation-server, grobid, ollama
(+ a one-shot model pull), a nightly `pg_dump` and its rclone mirror to Garage.
No SeaweedFS: that's for local development only.

## 1. What's landed

| Piece | Where | State |
|---|---|---|
| Garage bucket `reference-manager` (+ CORS for `https://bib.krg.ucsd.edu`, GET/HEAD, `range`) and key `reference-manager` (rw on that bucket) | `spec/e4e-nas/garage.yml` (#558, CORS fixed in #560/#561) | live. CD minted `secret/e4e-nas/garage-keys/reference-manager` (create-once, `deploy/deploy-ansible.sh`) and `synology_garage` imported it. No manual OpenBao step. |
| Boundary: Incus project + quota | `terraform/incus` `var.tenants.reference-manager` | live: project (#559), instance + shared forward port 30444 (#562, #563) |
| OpenBao AppRole `tenant-reference-manager` | `terraform/openbao` `var.tenants.reference-manager` | applied by the operator 2026-10-07 (privileged; CD never applies `openbao`) |
| Generated secrets `tenants/reference-manager/generated/app` `{db_password, session_secret}` | `terraform/secrets/reference_manager.tf` | live (#559, krg-deploy's `tenants/+/generated` glob) |
| Authentik OIDC provider + app (slug `reference-manager`), client secret → `tenants/reference-manager/oidc/web` | `terraform/authentik/reference_manager.tf` | live (#559, `tenants/+/oidc` glob) |
| krg-zone edge | `nix/hosts/krg-prod` `krg.edge` (`provider = "file"`) + the `krg-edge-routes` unit | live (#559); bib route live (#562), hot-reloaded |

### The CORS header-case gotcha

Garage matches `AllowedHeaders` **case-sensitively**, and browsers send
`Access-Control-Request-Headers` **lowercased** (`range`, never `Range`). #558's rule
listed `Range`, so every real pdf.js preflight got a 403 while a hand-written
`curl -H 'Access-Control-Request-Headers: Range'` returned 200 and looked fine. Since
#561 `synology_garage` lowercases `allowed_headers` on apply, so the spec's case no
longer matters. Always test a preflight with the **lowercase** header (§5).

## 2. The boundary (reference)

**a. OpenBao.** `terraform/openbao` `var.tenants`:

```hcl
reference-manager = {
  kv_prefix        = "tenants/reference-manager"
  extra_read_paths = ["e4e-nas/garage-keys/reference-manager"]
}
```

`extra_read_paths` is new with this tenant. The Garage key's source of truth is the
e4e-nas key store (create-once, imported into Garage from there), so the slot reads it
**in place** rather than from a copy under `tenants/` that would go stale on rotation.
It's one exact path, read-only.

**b. Incus.** `terraform/incus` `var.tenants`, final form after the flip (§4):

```hcl
reference-manager = {
  zone      = "krg"
  cpu       = 6
  memory    = "12GiB"
  disk      = "60GiB"
  isolation = "virtual-machine"
  image     = "krg-golden"     # flip
  nat_ip    = "10.100.0.11"    # flip
  edge_port = 30444            # flip
  repo      = "UCSD-E4E/e4e-reference-manager"
}
```

The first four fields are `nix eval .#krgTenant.terraformTenant --json` from the tenant
flake. krg-nat had 16 cores, 98 GiB RAM (56 available) and 960 GB free on 2026-10-06,
so the quota fits.

**c. Edge route.** `nix/hosts/krg-prod/default.nix` `krg.edge.routes` (flip):

```nix
reference-manager = {
  subtree = "bib.krg.ucsd.edu";
  hostnames = ["bib.krg.ucsd.edu"];
  backend = "137.110.161.105:30444"; # krg-nat:edge_port → network forward → 10.100.0.11:443
  # serverName defaults to "reference-manager.vm"; reencrypt to true.
};
```

The route renders into a file-provider config. The `krg-edge-routes` unit copies it
into `/var/lib/krg/krg-prod/traefik-edge/`, which krg-prod's compose Traefik watches,
so adding the route **hot-reloads** Traefik: no krg-prod stack restart, no blip for the
other lab services. (This PR's own compose change restarts the stack once, as every
krg-prod compose change does.) Firewalls need no change: both krg-nat layers (in-guest
`tenantIngressSources` and Proxmox `krg-nat.fw`) already let krg-prod reach
30000–30999.

**d. DNS: request one CNAME** (outside this repo):

```
bib.krg.ucsd.edu.  CNAME  krg-prod.ucsd.edu.
```

Same target as the other `*.krg.ucsd.edu` names. No other name is needed: PDFs come
from the existing `s3.e4e.ucsd.edu`.

## 3. Gates before the flip

Status as checked on 2026-10-07.

1. **#559 merged and deployed.** ✅ Run 37572404376 (c489471) applied it: the `incus`
   plan created `incus_project.tenant["reference-manager"]` only, `secrets` created
   one KV secret, `authentik` created the provider, app and KV secret, and krg-prod
   started `krg-edge-routes.service`.
   **Check the post phase, not the run's conclusion.** A `Deploy fleet` run whose
   checked-out commit isn't main head ends in ~8 s with `success` and the notice
   "is not current main head — skipping (no downgrade)". Its "Apply to fleet
   (systems + config + verify)" job is `skipped`. Only a run where that job is
   `success` applied anything:
   `gh run view <id> --json jobs --jq '.jobs[] | "\(.name)=\(.conclusion)"'`.
2. **The Garage PR merged and deployed.** ✅ Same run: `garage: 3 key credential(s)
   ready in OpenBao: … reference-manager`, then `synology_garage` on e4e-nas. Check the
   key exists (keys only, no values):
   `bao kv get -format=json secret/e4e-nas/garage-keys/reference-manager | jq -c '.data.data|keys'`
   → `["access_key_id","secret_access_key"]`. Also check the two other paths the slot
   renders, because vault-agent is fail-closed: `tenants/reference-manager/generated/app`
   → `["db_password","session_secret"]` and `tenants/reference-manager/oidc/web` →
   `["client_id","client_secret","issuer_url"]`. ✅ all three.
   **The CORS fix (#561) must be applied too** before a browser can view a PDF (§1, the
   header-case gotcha). Check with the §5 preflight.
3. **Privileged OpenBao apply** (creates the AppRole + its policy). From an up-to-date
   main checkout on krg-deploy, as `krg-admin`:
   ```bash
   cd /var/lib/krg-admin/krg-infra && git pull --ff-only
   # 1) plan only
   TOFU_TARGETS=openbao TOFU_PLAN_ONLY=1 TOFU_OPENBAO_TOKEN=<privileged token> \
     TOFU_STATE_PASSPHRASE=<state passphrase> ./deploy/deploy-tofu.sh
   # 2) apply, once the plan matches
   TOFU_TARGETS=openbao TOFU_OPENBAO_TOKEN=<privileged token> \
     TOFU_STATE_PASSPHRASE=<state passphrase> ./deploy/deploy-tofu.sh
   ```
   Expected plan: **2 to add, 0 to change, 0 to destroy**:
   `vault_policy.tenant["reference-manager"]` and
   `vault_approle_auth_backend_role.tenant["reference-manager"]`. **No change** to
   `tenant-fishsense` (its policy text is unchanged by design). Anything else in the
   plan is unrelated drift; stop and look before applying.
4. **The app repo carries the interior** (HANDOFF §2) and the app changes in HANDOFF §6.
   ✅ Releases come from **release-please**, not hand-pushed tags: merging its release
   PR cuts the GitHub release, builds and pushes both images at that version, and
   opens `auto-deploy/vX.Y.Z`. The first release was **v1.0.0**.
   `ghcr.io/ucsd-e4e/e4e-reference-manager-{api,web}:v1.0.0` exist and pull
   anonymously, and `auto-deploy/v1.0.0` is merged, so main's compose pins v1.0.0. Its
   `flake.lock` pins krg-infra at c489471, which carries the krg edge.
5. **The app repo is PUBLIC.** ✅ (It was private on 2026-10-06.)
   `reference-manager-selfupdate` and the nightly `system.autoUpgrade` fetch
   `github:UCSD-E4E/e4e-reference-manager` anonymously (`nix/modules/tenant.nix`), so a
   private repo could never converge or patch itself.
6. **The runner GitHub App is installed on UCSD-E4E/e4e-reference-manager.** ✅ Check on
   krg-deploy:
   `./deploy/mint-runner-token.sh --is-registered UCSD-E4E/e4e-reference-manager reference-manager`.
   It answers `runner 'reference-manager' is NOT registered …` (rc=1) when the App
   can see the repo. `could not list runners` means it can't. Without it, phase 3.6
   warns and mints nothing, and the slot has no runner.
7. **The CNAME is published** (§2d). ✅ `bib.krg.ucsd.edu → krg-prod.ucsd.edu → 137.110.161.106`.
   It gates only the edge route, not the slot.
## 4. The flip PR

One krg-infra PR: §2b's three fields and §2c's route. Merge it only **after** gate 3's
apply. Merged earlier, phase 3.6 skips the slot ("AppRole not found", a warning, not a
red deploy), and it waits for the next deploy for its secret-zero. With all gates
passed, CD then:

- creates the instance from `krg-golden` at 10.100.0.11, and the forward
  `137.110.161.105:30444 → 10.100.0.11:443`;
- phase 3.6 stages secret-zero (`tenant-reference-manager` role-id + secret-id) and a
  runner registration token into the instance;
- krg-prod's Traefik picks up the route and issues the LE cert for `bib.krg.ucsd.edu`
  (HTTP-01; needs the CNAME).

The golden image doesn't run the app yet. The first converge onto the tenant flake is
by hand, as for fishsense:

```bash
# --env PATH: `incus exec` starts with a bare PATH, so systemctl/docker aren't found without it.
slot() { ssh krg-admin@krg-nat.ucsd.edu "incus exec reference-manager --project reference-manager --env PATH=/run/current-system/sw/bin -- $*"; }
slot nixos-rebuild switch --flake github:UCSD-E4E/e4e-reference-manager#reference-manager --refresh
slot systemctl show openbao-agent.service reference-manager.service -p Id -p Result   # both success
slot docker ps -a --format '{{.Names}} {{.Status}}'   # ollama-models: Exited (0) once both models are pulled
```

Exit 4 from `switch-to-configuration` is not the signal; the unit results are. From
then on, merged `auto-deploy/*` PRs in the app repo converge the slot.

### What happened on the real bring-up (2026-10-07)

- **The flip deploy went red: one forward per listen address.** Incus allows a single
  network forward per IP. `forwards.tf` made one per tenant on krg-nat's shared IP,
  so the second exposed tenant failed with `A forward for that listen address
  already exists`. Fixed in #563: one shared forward with one port per tenant,
  fishsense's adopted via `moved`. The plan was `0 to add, 1 to change` in place.
  incus is the last tofu target, so that run also skipped phase 3.6 (secret-zero).
- **The runner raced the manual converge.** The switch starts the runner. It
  registers within seconds and immediately takes any QUEUED app Deploy job (here,
  `auto-deploy/v1.0.0`, merged before the slot existed). That job starts
  `reference-manager-selfupdate`, whose `nixos-rebuild` then collides with the
  running switch (`Unit nixos-rebuild-switch-to-configuration.service was already
  loaded`). It fails, and the runner it stopped stays down. The switch itself
  landed (exit 4 only flagged the failed selfupdate). Recovery:
  `slot systemctl reset-failed reference-manager-selfupdate.service`, then
  `slot systemctl start github-runner-reference-manager.service`. Leaving the
  selfupdate unit `failed` would make every later switch exit 4. **For the next
  tenant:** cancel queued app Deploy runs before the first converge, or let the
  queued job do the converge instead of running it by hand.
- **The stack's first start takes ~15 min** (pulling GROBID and Ollama, then the
  models), so `nixos-rebuild` returns only after it.
- **translation-server 2.0.4 self-upgrades its translators** (`git pull` in its
  entrypoint) to versions its Node 10 can't run, so every lookup 500s. Fixed in the
  interior with `entrypoint: ["npm", "start"]` (HANDOFF copy updated).
- The slot's transient hostname stays `krg-golden` until its first reboot
  (`networking.hostName` = `reference-manager` takes effect at boot). Cosmetic.

## 5. Verify

Results from 2026-10-07 are noted inline.

- `curl -sI https://bib.krg.ucsd.edu/` → 200, LE-issued (not `(STAGING)`). ✅ issuer
  `Let's Encrypt YR2`; nginx serves the SPA, and `/libraries/x` → 200 (fallback).
- `curl -s https://bib.krg.ucsd.edu/api/health` → `{"status":"ok"}`. ✅ Unauthenticated
  `/api/auth/me` → 401.
- `/api/auth/login` → 302 to `auth.krg.ucsd.edu/application/o/authorize/` with
  `client_id=reference-manager`, `redirect_uri=https://bib.krg.ucsd.edu/api/auth/callback`
  and `scope=openid email profile groups`. Authentik accepts it (→ its login flow).
  The issuer at `/application/o/reference-manager/` publishes an RS256 JWKS. ✅
- Log in: the browser lands on `auth.krg.ucsd.edu`, then on `https://bib.krg.ucsd.edu/`.
  (Needs a human; see below.)
- CORS preflight, with the header **lowercase** as browsers send it (§1):
  ```bash
  for o in https://bib.krg.ucsd.edu https://evil.example; do
    curl -s -o /dev/null -w "$o %{http_code}\n" -X OPTIONS https://s3.e4e.ucsd.edu/reference-manager/x \
      -H "Origin: $o" -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: range'
  done   # bib → 200, evil → 403
  ```
  ✅ bib → 200 (`access-control-allow-headers: range`), evil → 403.
- Storage, server side, without exposing a credential: inside `reference-manager-api-1`,
  use the app's own `app.storage` to `upload_bytes` a probe object, `presigned_get_url`
  it, fetch it with `Range: bytes=0-99` + `Origin: https://bib.krg.ucsd.edu`, print
  only status + headers, then delete it. ✅ upload ok; **206**,
  `Content-Range: bytes 0-99/1009`, `Access-Control-Allow-Origin: https://bib.krg.ucsd.edu`,
  the pdf.js headers exposed.
- Upload a PDF in the browser and open it in the viewer. The PDF requests go to
  `s3.e4e.ucsd.edu` with `Range` headers and 206 responses. (Needs a human.)
- Slot: `ollama-models` Exited (0), `qwen2.5:3b` + `nomic-embed-text` present; GROBID
  `/api/isalive` → true; Alembic at head. The app repo's own `verify-incus` passed
  (deployed pins = main's v1.0.0, stack `success`). ✅
- Next day: `slot docker logs reference-manager-pg-backup-sync-1 | tail` shows `synced`.

## Notes / follow-ups

- **Who can sign in**: any authenticated Authentik user (no `app_access.tf` binding),
  which includes enrolled external collaborators. To restrict it, add
  `reference_manager = ["<AD group>"]` to `app_group_access`.
- **Monitoring**: no blackbox probe yet; add `https://bib.krg.ucsd.edu/api/health` to
  Prometheus' blackbox targets once it's live.
- **Backups** are a sleep-loop pair of containers (`pg-dump`, `pg-backup-sync`), the
  simplest thing that works. The platform's Temporal-based backup template (ADR 0017)
  can replace them when it exists.
- **Platform follow-ups found during bring-up** (not specific to this tenant):
  - `deploy/deploy-authentik-sync.sh` looks for container `authentik_worker`, but the
    compose service has no `container_name`, so it runs as `krg-prod-authentik_worker-1`.
    The AD→Authentik sync step fails (non-fatally) on every deploy.
  - Every fleet deploy restarts `openbao-agent` on krg-prod twice (phase 2
    `deploy-nixos.sh`, phase 3.5 `deploy-rerender-secrets.sh`). `krg-prod.service`
    `requires` it, so each restart runs `docker compose down` and bounces every lab
    service.
