# fishsense-lite → Incus platform: interior hand-off

fishsense is **tenant #1** on the KRG Incus platform ([ADR 0017](../../adr/0017-incus-nat-self-serve-platform.md) /
[ADR 0020](../../adr/0020-tenant-deploy-contract-mktenant.md)). The **admin boundary is
built, deployed, and validated on real hardware** (2026-07-05). This directory is the
starter package for the tenant-owned **interior** — copy `flake.nix` + `deploy/` into
`UCSD-E4E/fishsense-lite`. This doc is the hand-off: what's done, what you own, and the two
platform seams your full go-live still waits on.

Full runbook context: [`docs/onboarding-fishsense.md`](../../onboarding-fishsense.md).

---

## 1. What the platform admin has provisioned (DONE — validated on-box)

| Piece | Where | State |
|---|---|---|
| OpenBao AppRole + least-priv policy | `terraform/incus`→`terraform/openbao` var.tenants.fishsense (`kv_prefix=tenants/fishsense`) | ✅ applied |
| Incus project + quota (cpu 4 / 8GiB) | `terraform/incus` | ✅ applied |
| Slot booted from `krg-golden` | Incus `fishsense` project | ✅ **RUNNING at 10.100.0.10** |
| Ingress network forward | `terraform/incus` forwards.tf: krg-nat:30443 → 10.100.0.10:443 | ✅ conntrack-proven from the e4e edge |
| Firewall (both layers) | ansible `krg-nat.fw` + in-guest `krg.firewall` open 30000-30999 to the edges | ✅ |
| e4e-prod edge route | `nix/hosts/e4e-prod` `krg.edge.routes.fishsense` | ✅ loaded |
| Public **production** LE cert | `fishsense.e4e.ucsd.edu`, issuer `CN=YR2` | ✅ issued + served |

So the **public front door is live** and serving a trusted cert. `curl https://fishsense.e4e.ucsd.edu`
completes TLS at the edge today; it just has no backend to answer yet — that's your interior.

### The ingress chain (don't change its shape)
```
public → e4e-prod edge (prod LE cert, TLS-terminate)
       → re-encrypt HTTPS, verify serverName=fishsense.vm vs the fleet CA
       → krg-nat:30443  → incus_network_forward → 10.100.0.10:443
       → YOUR inner traefik (serves fishsense.vm, routes Host → containers)
```
Because the route is **reencrypt=true**, your inner traefik **must listen on :443 and serve
the `fishsense.vm` cert** (not a plain internal port — that's the difference from the generic
template).

---

## 2. What you own (the interior — authoritative, repo-owns-deploy)

1. **`flake.nix`** — the `mkTenant` declaration (this dir has it, filled for fishsense). Pin a
   real krg-infra `<REV>` **≥ #431** (the rev that wires the in-instance vault-agent cert **and**
   the repo-owns-deploy runner). Add your `hardware-configuration.nix` (capture it from the
   running slot: `incus exec fishsense --project fishsense -- nixos-generate-config --show-hardware-config`).
2. **`deploy/compose.yml`** — your project stack + an inner traefik (this dir has a skeleton;
   swap the placeholder `ghcr.io/ucsd-e4e/fishsense-lite-*` images for the real ones, wire
   `traefik-dynamic.yml` routers). The stack routes:
   - `fishsense.e4e.ucsd.edu` → web
   - `orchestrator.fishsense.e4e.ucsd.edu` → API
   - `analytics.fishsense.e4e.ucsd.edu` → superset
   - workers reach krg-prod Temporal over gRPC (automatic egress NAT).
3. **`.github/workflows/auto-deploy.yml`** — the ~6-line workflow that runs on your
   platform-provided runner and triggers the switch on a merged `auto-deploy/*` PR (the exact
   YAML is in §3B). This is how a merge converges the instance.
4. **App secrets** — seed under `secret/tenants/fishsense/*` in OpenBao; the in-instance
   vault-agent renders them (Postgres password, app OIDC, etc.). You own the values.

---

## 3. Platform seams — both built; what's left is yours to declare

The cert design is settled in [ADR 0021](../../adr/0021-tenant-tls-vault-agent-and-secret-zero.md).

- **A. vault-agent → `fishsense.vm` cert — DONE + validated.** `nixosModules.tenant` runs the
  in-instance vault-agent, which mints the `tenant-internal` cert (from the `tenant-fishsense`
  AppRole) and renders it to **`/run/tenant/tls/fishsense.vm.{crt,key}`** — the path
  `deploy/compose.yml` mounts (#428). Its secret-zero (`role-id`+`secret-id`) is pushed into the
  instance **automatically** by krg-deploy every deploy (CD Phase 3.6, #429) — no manual staging.
  You don't place a cert by hand. The agent **fails closed** if OpenBao is unreachable (the stack
  won't start with a missing cert). Nothing for you to do here.
- **B. repo-scoped GitHub App runner — BUILT (#431), and mostly automatic for you.** The
  platform now provisions a self-hosted runner scoped to your repo: because your `flake.nix`
  sets `repo = "UCSD-E4E/fishsense-lite"`, `nixosModules.tenant` runs a runner and krg-deploy
  brokers + pushes its registration token every deploy (GitHub App → `incus file push`, ADR
  0022). You don't manage a runner token. **What you own:** a tiny `.github/workflows/auto-deploy.yml`
  in fishsense-lite that runs on the runner and triggers the switch on a merged `auto-deploy/*` PR:

  ```yaml
  on: { push: { branches: ["auto-deploy/**"] } }
  jobs:
    deploy:
      runs-on: [self-hosted, fishsense]        # the label the platform sets
      steps:
        - run: systemctl start fishsense-selfupdate   # polkit-authorized; converges the instance
  ```
  The `fishsense-selfupdate` unit does `nixos-rebuild switch --flake github:UCSD-E4E/fishsense-lite#fishsense`,
  bringing up your config + the compose interior. (Your repo must be **public** for the flake
  fetch, for now.) **One-time bootstrap** (admin, after your flake first exists): `incus exec
  fishsense --project fishsense -- nixos-rebuild switch --flake github:UCSD-E4E/fishsense-lite#fishsense`
  installs the runner; it self-sustains after. This is the last thing between "front door live"
  and "end-to-end green".

## 4. Extra public names (orchestrator / analytics)
Only the **apex** CNAME is published + in the edge SAN list today. `orchestrator.` and
`analytics.` each need (1) their CNAME → e4e-prod filed, then (2) a one-line `hostnames`
addition to `krg.edge.routes.fishsense` (the subtree HostRegexp already matches them — no new
route). Request them one at a time.

---

## 5. Bring-up order
1. Finalize `flake.nix` (pin REV, add hardware-config) + `deploy/compose.yml` (real images +
   `traefik-dynamic.yml`) + `.github/workflows/auto-deploy.yml` (§3B) in `UCSD-E4E/fishsense-lite`.
2. Seed `secret/tenants/fishsense/*`; the vault-agent renders `fishsense.vm` + app secrets.
3. Admin runs the one-time bootstrap (§3B) → the runner installs + registers on fishsense-lite;
   a merged `auto-deploy/*` PR then converges the interior. Verify the inner traefik serves
   `fishsense.vm` on :443.
4. `https://fishsense.e4e.ucsd.edu` goes fully live — the edge's re-encrypt verifies the cert by
   chain and routes to `web`. Add orchestrator/analytics SANs as their CNAMEs land (§4).

---

## 6. Talking to krg-prod Temporal

- **Endpoint:** `krg-prod.ucsd.edu:7233` — the raw gRPC frontend (NOT behind Traefik;
  `workflows.krg.ucsd.edu` is the *UI*). Public + mTLS-gated ("the cert is the access control,
  not the network"). Reachable from **both** your in-slot workers (10.100.0.10 via egress NAT)
  and your off-prem NRP data-worker.
- **Namespace:** `fishsense` (dedicated, retention 30d) — exists.
- **Auth:** **mTLS only** (no OIDC/API-key). Present a `temporal-client` cert; verify the server
  against the lab CA (`issuing_ca`); set the gRPC TLS **server-name override to
  `workflows.krg.ucsd.edu`**.
- **Client-cert delivery** (ADR 0023):
  - **In-slot workers — WIRED.** Set `temporal = { namespace = "fishsense"; }` in your `mkTenant`
    call (the admin grants `pki_int/issue/temporal-client` on your tenant policy). Your in-VM
    vault-agent then renders a `fishsense-worker` client cert to
    **`/run/tenant/temporal/{tls.crt,tls.key,ca.crt}`**, auto-renewed — mount it into your workers
    like `fishsense.vm`. Fail-closed if OpenBao is unreachable.
  - **Off-prem NRP worker — manual (interim).** NRP is off our OpenBao, so it can't self-render:
    an admin mints a 30-day `temporal-client` cert and hands you the PEM trio to load as a k8s
    Secret; renew at 30 days. (Automated krg-deploy→NRP-Secret delivery is a tracked follow-up —
    needs an NRP kubeconfig on krg-deploy.)
- **⚠️ Namespace isolation is by convention, not enforced** — OSS Temporal mTLS authenticates the
  *connection*, not per-namespace access; any valid client cert can target any namespace. Fine
  while you're the only tenant; a per-namespace authorizer is tracked in **#434** before a second
  distrusting tenant shares Temporal.

## 7. Auth per route (unauthenticated / OIDC / proxy)

Auth lives in **your inner Traefik** (per-path, under your control) — the edge is auth-agnostic
(per-hostname, too coarse for mixed routes). The Authentik resources you need **already exist** in
`terraform/authentik`:

| Your route type | Authentik resource (exists) | Where it runs |
|---|---|---|
| Unauthenticated | — | edge passes straight through |
| OIDC (web app, Superset) | `fishsense_oauth`, `fishsense_analytics` OAuth2 providers | in-app (your OIDC flow) |
| Proxy-protected (orchestrator) | `fishsense_orchestrator` proxy provider (`forward_single`), bound to the krg-prod proxy outpost + a `FishSense`-group access policy | your inner Traefik `forwardAuth` middleware |

To gate the orchestrator router, reproduce the old `authentik@docker` behavior in your
`traefik-dynamic.yml`: a `forwardAuth` middleware → the proxy outpost's
`/outpost.goauthentik.io/auth/traefik`, applied to the **orchestrator router only** (leave the OIDC
and public routers alone). **Working reference in this repo:** `guacamole_gate`
(`terraform/authentik/applications_krg.tf` + the `authentik` middleware in `compose.authentik.yml`)
— same outpost, same `forward_single` mode.

## 8. Operational answers (quota / egress / subdomains / runner)

- **Resource quota:** current 4 vCPU / 8 GiB / 20 GiB disk. krg-nat has **16 vCPU / 98 GiB** (ample
  headroom), so 6 vCPU / 12 GiB is fine. Bumping = an admin one-liner in `terraform/incus`
  `var.tenants.fishsense` + `tofu apply` (a memory *raise* may want an instance restart). Same
  one-liner to raise later; the ceiling is krg-nat's capacity, shared across tenants.
- **Egress: open NAT, no allowlist.** Your instance SNATs out krg-nat's uplink and nothing filters
  outbound — Temporal gRPC, Garage S3, FileStation HTTP, the NRP k8s API, Label Studio, and
  Authentik OIDC all just work. Only *inbound* is restricted (30000–30999 from the edges).
- **Subdomains:** each extra public name (`orchestrator.`, `analytics.`) = (1) request the CNAME →
  `e4e-prod.ucsd.edu` (DNS admin — the long pole, one at a time), then (2) a one-line add to
  `krg.edge.routes.fishsense.hostnames` (PR + one deploy → LE re-issues the multi-SAN cert). The
  `subtree` HostRegexp already matches them, so no new route. `workflows.` no longer needed.
- **Runner coexistence:** the self-hosted runner is **opt-in per job by label**
  (`[self-hosted, fishsense]`). Your NRP job (`runs-on: ubuntu-latest`) is untouched; your in-slot
  job uses `runs-on: [self-hosted, fishsense]`. **Don't** use bare `runs-on: self-hosted` for NRP
  jobs — that label matches ours.

## 9. Wiring app secrets into your containers

`nixosModules.tenant`'s vault-agent renders only the **certs** (`fishsense.vm`, temporal). Your
**app secrets** need their own renders — which you add in **your** flake (your config extends
`krg.vaultAgent.renders`; the list merges with the platform's). The tenant AppRole already reads
`secret/data/tenants/fishsense/*`, so it can render everything under there.

Two kinds of secret live under `secret/tenants/fishsense/`:
- **You seed** the app-internal ones — `postgres` (`password`), `superset` (`secret_key`), … (§6).
- **The platform writes** the OIDC client secrets — `oidc/web` and `oidc/analytics`
  (`client_id` / `client_secret` / `issuer_url`), generated by Authentik and written by tofu
  (you do NOT seed these).

Render them to a tmpfs env file and mount it:

```nix
# in a module in your flake, alongside { krg.tenant = ...; }
{
  krg.vaultAgent.renders = [{
    destination = "/run/tenant/secrets/app.env";
    contents = ''
      {{ with secret "secret/data/tenants/fishsense/postgres" }}POSTGRES_PASSWORD={{ .Data.data.password }}{{ end }}
      {{ with secret "secret/data/tenants/fishsense/superset" }}SUPERSET_SECRET_KEY={{ .Data.data.secret_key }}{{ end }}
      {{ with secret "secret/data/tenants/fishsense/oidc/web" }}OIDC_CLIENT_ID={{ .Data.data.client_id }}
      OIDC_CLIENT_SECRET={{ .Data.data.client_secret }}
      OIDC_ISSUER={{ .Data.data.issuer_url }}{{ end }}
    '';
  }];
}
```
```yaml
# in deploy/compose.yml — mount the rendered env into the services that need it
services:
  api:      { env_file: [/run/tenant/secrets/app.env] }
  superset: { env_file: [/run/tenant/secrets/app.env] }
```

KV-v2 reads use the `secret/data/<path>` form with fields under `.Data.data`. The agent is
**fail-closed** (`errorOnMissingKey` defaults true): a missing secret takes the stack down rather
than starting with an empty value — so seed everything first. A rotated secret re-renders on the
next deploy and restarts the stack.
