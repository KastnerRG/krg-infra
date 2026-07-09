# 0015. Fleet-wide container logs to Loki via journald + per-host Alloy

**Status:** Proposed · **Date:** 2026-06-25

## Context

The lab-wide monitoring stack (Prometheus, Grafana, Loki, Alloy, Blackbox) runs as
Docker Compose on **krg-prod** (`nix/docker-compose/krg-prod/`). Grafana already has a
Loki datasource (`terraform/grafana/datasources.tf`, uid `krg-loki-ds`) and Alloy
(v1.17.0) ships the krg-prod systemd journal to Loki. The intent — stated in
`nix/modules/docker.nix:108-112` and `docs/fleet-inventory.md` ("Loki + Promtail,
planned fleet-wide") — is for **every host's container logs** to be queryable in
Grafana. Today that intent is unmet in two ways, one of them silent.

**Gap 1 — container *application* logs are not captured anywhere shippable, even on
krg-prod.** The Docker daemon has **no `log-driver` set** (`docker.nix` configures only
`metrics-addr`, `ip`, and builder GC), so it defaults to **`json-file`**. With
json-file, a container's stdout/stderr is written to
`/var/lib/docker/containers/*/*-json.log` and **does not enter the systemd journal** —
only dockerd's own lifecycle messages (container start/stop/health) do. Alloy reads the
journal (`loki/config.alloy`), so it ships daemon chatter but **not** the logs *inside*
Authentik, Grafana, Postgres, etc. The config comment asserting "everything (incl.
container logs via docker.service) goes to the journal" is incorrect for application
logs. Result: the Loki datasource exists but is largely empty of container content even
on the one host running the full stack.

**Gap 2 — no shipper and no reachable Loki on the rest of the fleet.** Alloy is a
krg-prod-only compose service reading only that host's journal. Loki is published at
**`127.0.0.1:3100`** (loopback, via `krg.docker.defaultPublishAddress`) with no Traefik
route and no external hostname. waiter / e4e-prod / krg-ldap / fabricant have neither a
log shipper nor a network path to Loki.

Two constraints shape the solution:

- **The Loki docker log-driver plugin is already rejected** (`docker.nix:108-112`): a
  dead Loki endpoint can hang `docker`, and `docker plugin install` on first boot is
  fragile. We do not want container logging to sit in the container runtime's critical
  path.
- **Raw published ports bypass the in-guest firewall.** Docker DNATs published ports
  through the FORWARD path, past `krg.firewall`'s INPUT rules (the open dcgm-9400 / PVE
  6636 item in CLAUDE.md). Opening a raw `:3100` to the fleet would repeat that bypass.
- **The fleet is not flat — [ADR 0008](0008-e4e-prod-tenant-platform.md) adds nested
  tenant guests.** e4e-prod hosts one **microVM per tenant**, each running its own Docker
  + compose stack, so "container logs across the fleet" includes N nested guests that are
  *appliance-like and do not import `base.nix`* — the shipper must be wired by
  `krg.tenants`, not the base profile. The property that actually reshapes the
  requirement is **ephemeral root**: both the platform host and every tenant VM roll back
  on reboot/redeploy ("repair by redeploy" is literal), so local logs are **destroyed**
  on every reset — for tenants, central shipping is the *only* surviving record of a
  crash-loop or a compromise foothold, turning this from observability into **forensic
  durability**. Cross-tenant log *isolation* is explicitly **not** a driver: ADR 0008's
  tenants are **semi-trusted, not hostile**, and the VM is the real boundary, so a
  compromised tenant reading another's logs is out of the threat model. A per-tenant
  *label* (for querying and noisy-neighbor rate limits) is wanted; hard Loki tenancy as a
  read-isolation wall is not.

## Decision

Ship container logs the same way we ship system logs — **through the systemd journal,
one shipper per host** — by closing the json-file gap and federating the existing Alloy
design across the fleet. Four parts:

**A. Set the Docker daemon log-driver to `journald` fleet-wide** in `nix/modules/docker.nix`
(daemon settings), with `--log-opt tag` carrying a container-name label. Container
stdout then flows **container → journald → Alloy → Loki**, unifying with the journal
path Alloy already reads and keeping logging *out* of the container runtime's critical
path (the rejected plugin's failure mode). Because journald rate-limits by default,
raise `RateLimitBurst`/`RateLimitIntervalSec` so high-volume containers don't silently
drop lines.

**B. Promote Alloy to a native per-host NixOS module** (`services.alloy`) enabled in
`nix/profiles/base.nix`, reading the local journal and pushing to Loki, with a **`host`
label** relabeled from the hostname so streams are distinguishable. fabricant
(Debian/Proxmox, ansible) gets an equivalent `ansible/roles/alloy`. The krg-prod compose
Alloy is retired in favour of the module so there is one shipper design, not two.

**C. Expose Loki through Traefik on 443, authenticated by mTLS over the existing OpenBao
PKI** — not a raw port. A push endpoint (`logs.krg.ucsd.edu`) fronted by Traefik gives
every host a network path **without** opening a new Docker-forwarded port (sidestepping
the in-guest firewall bypass a raw `:3100` would reintroduce). For auth, reuse the fleet
CA ([ADR 0009](0009-lab-internal-pki-ad.md)): each shipper presents a
**vault-agent-rendered client cert** (`krg.vaultAgent`, [[vault-agent-keystone]]). The
job here is modest — keep arbitrary network clients (and a compromised *non*-shipper
host) from injecting into Loki — not to wall tenants off from each other. mTLS is chosen
over a shared basic-auth secret only because the PKI + vault-agent render path already
exists and is the platform's idiom, and the per-shipper cert CN gives a free, trustworthy
source for the `tenant`/`host` label (part E) — not because tenant isolation demands it.

**D. Configure Loki retention before fan-in.** Loki is single-binary, filesystem,
replication 1, with **no retention/compactor**. Add a compactor + retention policy and
per-stream rate limits so multiplying ingest by the fleet size doesn't fill the krg-prod
disk.

**E. Tenant shippers via `krg.tenants`, labeled — single-tenant Loki.** Each tenant
microVM gets an Alloy generated **by the `krg.tenants` module** (not `base.nix` — tenant
VMs are appliance-like), pushing to the same Loki under a **`tenant` label** (plus
`host`/container). Loki stays **single-tenant**: a label is enough to query and dashboard
per tenant, and per-stream rate limits cover the noisy-neighbor case (the in-scope 0008
threat). We do **not** turn on `X-Scope-OrgID` multi-tenancy as a read-isolation wall —
semi-trusted tenants don't warrant it, and it adds per-org provisioning (datasources,
retention, overrides) for a boundary the VM already provides. Alloy's `--storage.path`
(read offsets/buffer) lands on `/persist` so it survives the ephemeral-root rollback.
**This part is gated on the unresolved secret-zero bootstrap into nested microVM
vault-agents** (ADR 0008 §3 open work) — until that lands, tenant shippers can't get their
mTLS client cert, so E ships *after* B for the plain fleet.

*Reserved, not adopted:* if a tenant later needs its own retention curve, a hard quota, or
a student-facing scoped Grafana view, promote that tenant to a real `X-Scope-OrgID` —
the mTLS cert CN already carries the identity to key it off. That's a per-tenant opt-in,
not the default.

Sequencing: **A on krg-prod first** (cheapest end-to-end validation that container app
logs reach Loki, and it fixes the misleading comment) → **D** (retention before the
volume grows) → **C** (the mTLS endpoint) → **B** (roll the module across the plain fleet
one host at a time: waiter → e4e-prod → krg-ldap → fabricant) → **E** (tenant shippers,
once nested secret-zero exists).

## Consequences

- Container application logs (not just daemon lifecycle) become queryable in Grafana,
  per host, via a `host` + container-name label scheme.
- One logging design fleet-wide: journald driver + a per-host journal shipper, mirroring
  how node/ipmi exporters are already native per-host rather than centralized.
- Logging stays out of the container runtime's critical path — a dead Loki backs up in
  Alloy/journald, not in `docker` (the reason the loki log-driver plugin was rejected).
- Switching to the journald driver means existing `/var/lib/docker/containers/*-json.log`
  files stop growing for new containers; `docker logs <ctr>` still works (journald
  backs it). Operators lose nothing, but the change is fleet-wide and wants a canary.
- krg-prod's disk now absorbs fleet-wide log volume; retention (part D) is a hard
  prerequisite, not a follow-up.
- A new soft dependency: each host's logs depend on reaching krg-prod's Loki over 443.
  Alloy buffers to its `--storage.path` when Loki is unreachable, so a krg-prod outage
  delays rather than drops logs (bounded by retention of the local buffer).
- For ADR 0008 tenants this is not optional polish: their ephemeral root means logs that
  aren't shipped are gone on redeploy/compromise-reset, so central, off-box logs are the
  *only* forensic record of a tenant VM. The buffer caveat above also has more bite —
  if a tenant resets before its Alloy buffer drains, the un-shipped tail is lost.
- Loki stays a single flat store with a `tenant` label — no per-org provisioning,
  retention, or datasource fan-out. The trade is that tenant separation is query-time
  convention, not enforced; accepted because the VM, not Loki, is the isolation boundary
  and tenants are semi-trusted. Promoting a tenant to a real org-id is reserved for a
  later, per-tenant need (retention/quota/scoped view).

## Alternatives considered

- **Loki docker log-driver plugin (per-container `logging.driver: loki`).** Rejected —
  already removed once (`docker.nix:108-112`): a dead Loki endpoint can hang `docker`,
  and `docker plugin install` on first boot is fragile. Puts logging in the runtime's
  critical path, the opposite of the journald-buffer behaviour we want.
- **Leave json-file; point Alloy at `/var/lib/docker/containers/*-json.log` via Docker
  service discovery.** Workable, but splits log collection into two sources (journal +
  json files) per host and needs Docker SD relabeling for container metadata. The
  journald driver gives one source and reuses the journal pipeline Alloy already runs.
- **Open a raw `:3100` to the fleet, firewall-restricted to host sources.** Rejected —
  Docker's FORWARD-path DNAT bypasses `krg.firewall`, so the port is world-reachable
  regardless of the rule (the open dcgm-9400 problem). Traefik-on-443 needs no new port.
- **Centralized scrape (Loki/Promtail pulls from each host).** Rejected — Loki is
  push-based and there is no pull-from-journal model; a per-host push agent is the
  standard topology and matches the existing Alloy design.
- **Keep logs local per host (status quo).** Rejected — defeats the monitoring goal;
  post-breach, central, tamper-evident logs off the originating host are the point — and
  for ADR 0008 tenants there *is* no durable local copy (ephemeral root), so local-only
  means no record at all.
- **Full `X-Scope-OrgID` multi-tenancy as the default for tenants.** Considered and
  **not adopted** — it walls tenants off from reading each other's logs, but ADR 0008's
  tenants are semi-trusted and the VM is already the boundary, so the wall guards against
  a threat outside the model while adding per-org datasource/retention/override config.
  A `tenant` label gives the query/dashboard separation we actually want; org-id is held
  in reserve for a per-tenant retention/quota/scoped-view need (part E).
- **Basic-auth (shared secret) at the edge instead of mTLS.** Rejected — but narrowly:
  the goal is only to keep arbitrary clients from injecting into Loki, which basic-auth
  would also do. mTLS wins on marginal cost (the PKI + vault-agent cert path already
  exists per ADR 0008/0009) and gives a trustworthy cert-CN source for the label, not on
  any isolation requirement.

## Out of scope / follow-ups

- **In-guest Docker-publish bypass.** Even with logs over 443, the underlying FORWARD
  bypass (`DOCKER-USER`/nftables FORWARD rule) remains the shared open item with dcgm
  9400 and PVE 6636 (CLAUDE.md "Docker published-port firewall bypass").
- **Per-host log retention vs. central retention.** This ADR sets central (Loki)
  retention; whether hosts also keep a longer local journal (`journald` `SystemMaxUse`)
  is a separate tuning decision.
- **Structured/JSON log parsing.** Label extraction beyond host/unit/container (e.g.
  level, request-id from JSON log lines) is deferred to per-service Alloy stages once
  the transport exists.
- **Alert rules on logs.** Loki ruler / Grafana log alerts are out of scope here; this
  ADR only establishes the pipeline.
- **Tenant shipper secret-zero.** Part E is gated on the same unresolved bootstrap as
  ADR 0008 §3 — staging the AppRole secret-zero into the nested microVM vault-agents so
  the tenant Alloy can render its mTLS client cert. Until that lands, only the plain
  fleet (A–D) ships; tenant shippers wait on it.
- **`krg.tenants` vs `base.nix` shipper wiring.** Part E assumes the tenant Alloy is
  emitted by `krg.tenants`, not the base profile. If a future tenant *does* import a
  fuller profile, reconcile so a tenant doesn't get two shippers (base + module).
