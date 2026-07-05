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
