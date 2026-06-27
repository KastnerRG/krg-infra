# 0018. Monitoring long-running VMs — agentless Incus metrics + dynamic discovery; monitoring follows persistence

**Status:** Accepted · **Date:** 2026-06-25

## Context

[ADR 0017](0017-incus-nat-self-serve-platform.md) introduces a self-serve Incus
platform where VMs are created and destroyed dynamically — by users (self-serve
sandboxes) and by admins (tenant services, operated apps). The lab's existing
monitoring stack (Prometheus + Grafana + Loki + Alloy + Blackbox on krg-prod,
node-exporter in `base`, Fleet/osquery, Blackbox probes) was built for a **static,
hand-curated fleet**: `prometheus.yml` lists named hosts. That model breaks the moment
targets churn — you cannot hand-edit a scrape config every time a researcher launches a
box. This ADR settles how the long-running (persistent) VMs are monitored without
abandoning the existing stack or the self-serve model.

Two facts shape the answer:

- Incus exposes a **Prometheus metrics endpoint** (`/1.0/metrics`, TLS-authed) reporting
  per-instance CPU/mem/disk/network for **every** instance — containers and VMs —
  measured at the hypervisor/cgroup level, **with no agent inside the guest**.
- [ADR 0017](0017-incus-nat-self-serve-platform.md) split the fleet into **ephemeral**
  (disposable, OEC-exempt, GC'd) and **persistent** (full baseline + OEC) tiers, and
  OEC enrollment follows that split. Monitoring has the same shape.

## Decision

### 1. Monitoring follows persistence

- **Ephemeral VMs:** agentless metrics + central log shipping for **visibility and
  forensics** (their ephemeral root makes central logs the only record — ADR 0015/0008).
  **No availability alerting** — they are *meant* to die; paging on their disappearance
  is noise.
- **Persistent VMs + service instances:** full agent depth + **availability alerting** +
  the compliance hooks (§5).

### 2. Targets are discovered, not curated

Static `prometheus.yml` host lists are retired for the platform fleet. Scrape targets
are **derived from the Incus instance list**, so the monitored set tracks reality as
instances come and go. (The existing static jobs for the fixed fleet — krg-prod,
krg-ldap, fabricant, waiter — remain; this is additive for the dynamic platform.)

### 3. Agentless per-instance metrics from the Incus endpoint (the foundation)

Prometheus scrapes the **Incus host's `/1.0/metrics`** over **mTLS using the OpenBao
PKI** (the same pattern [ADR 0015](0015-fleet-wide-container-logs-loki.md) chose for the
Loki push endpoint). One target → all instances, labeled, appearing/disappearing
automatically. Crucially this is **agentless and hypervisor-measured**, so it covers
instances whose interior the platform does *not* control — a user who disables their
in-guest node-exporter still shows up. This is the platform's capacity / abuse /
availability view and the base layer for every instance.

### 4. Three layers, mapped to provision-vs-manage

| Layer | Signal | Owner | Mechanism |
|---|---|---|---|
| **Agentless platform metrics** | per-instance resource use, capacity, availability | platform/admin | Incus `/1.0/metrics` → Prometheus (mTLS) |
| **Agent depth (persistent only)** | host metrics, logs, inventory | platform | node-exporter (`base`) + Alloy→Loki (ADR 0015) + Fleet/osquery, via service discovery |
| **App observability** | is-it-up + app internals | platform probes / tenant internals | Blackbox HTTP probes (platform) + the tenant's own `/metrics` + a granted Grafana folder |

This mirrors [ADR 0017](0017-incus-nat-self-serve-platform.md)'s boundary rule: **the
platform monitors the boundary (resources / availability / host); the tenant monitors
its app.** Tenants get a Grafana folder + datasource access for self-serve dashboards
rather than the platform building them.

### 5. Alerting is tied to platform responsibilities

Collection is not monitoring until something pages. Platform-owned alerts: persistent VM
down; disk / quota pressure (the deferred aggregate-capacity concern, ADR 0017); cert
expiry; **backup-job failure** (the Temporal backup template, ADR 0017); and — closing
the loop from the hardening decision — **OEC agent stopped reporting on a persistent
VM.** That last is *how* "OEC enforcement is detect-and-remediate"
([ADR 0017](0017-incus-nat-self-serve-platform.md) §7) is actually detected: a persistent
box whose Qualys/Trellix check-in drops → alert → re-enroll or reap.

### 6. Reuse the krg-prod stack; multi-tenancy by label

Everything feeds the **existing** Prometheus/Grafana/Loki/Alloy/Blackbox on krg-prod —
node-exporter is already in `base`, Fleet/osquery already runs, ADR 0015 is the log
pipeline. Tenant separation is **by label** (`instance` / `tenant` / `project`), **not**
hard read-isolation — consistent with [ADR 0015](0015-fleet-wide-container-logs-loki.md)
(semi-trusted; the VM is the boundary; cross-tenant read isolation is out of the threat
model). Per-tenant Grafana folders are convenience, not a security boundary.

### 7. Service-discovery mechanism

The agentless Incus endpoint covers resource metrics regardless of discovery. For the
**in-guest exporters** on persistent VMs: **file-based SD generated from the Incus API**
in phase 1 — a small periodic job that lists instances and writes a Prometheus targets
file. Dead simple, no new moving parts. Revisit **DNS-SD** off the managed-network
instance names at phase 2 (Incus already assigns instances DNS names) if file-SD churn
warrants it.

## Consequences

- Monitoring the dynamic platform needs **service discovery**; the static-config model
  is kept only for the fixed fleet.
- **One new scrape (Incus `/1.0/metrics`, mTLS) yields per-instance metrics for the
  entire platform agentlessly** — including ephemeral and user-managed boxes the
  platform can't trust to run an in-guest agent.
- The **OEC-dropout alert operationalizes** ADR 0017 §7's "detect-and-remediate";
  without it, that enforcement is only theoretical.
- Tenants get **self-serve Grafana** (a folder + datasource), consistent with
  provision-vs-manage; no hard per-tenant data isolation is built (label-scoped).
- **Phase 1 (Incus nested in Proxmox):** the Incus host is a VM on fabricant; its
  `/1.0/metrics` + node-exporter are scraped by krg-prod, while fabricant itself stays
  monitored via the ansible `monitoring` role. Nested-IO pressure
  ([ADR 0004](0004-vm-disk-io-budget.md)) is a first-class dashboard/alert.
- Net-new build is small and additive to the krg-prod stack: the metrics scrape, the SD
  job, Grafana folders, and the alert rules.

Related: [ADR 0004](0004-vm-disk-io-budget.md) (nested-IO pressure to surface),
[ADR 0006](0006-no-oec-on-dsm.md) (OEC, whose dropout we alert on),
[ADR 0008](0008-e4e-prod-tenant-platform.md) (tenants; ephemeral-root forensics),
[ADR 0009](0009-lab-internal-pki-ad.md) (the mTLS PKI),
[ADR 0015](0015-fleet-wide-container-logs-loki.md) (the log pipeline + mTLS endpoint
pattern + label-multi-tenancy),
[ADR 0017](0017-incus-nat-self-serve-platform.md) (the platform; persistence tiers; OEC
detect-and-remediate; backup template; capacity governance).
