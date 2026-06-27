# 0019. Proxmox → Incus migration — fabricant as the primary NixOS+Incus host, growing into a 3-node cluster

**Status:** Accepted · **Date:** 2026-06-25

## Context

[ADR 0017](0017-incus-nat-self-serve-platform.md) puts the self-serve/tenant platform
on Incus, and the [[nix-everything-north-star]] wants the hypervisor tier in the flake.
This ADR settles **how the existing Proxmox fleet gets there**, under hard hardware
constraints that rule out the clean "separate storage and compute hosts" plan:

- **No new *compute-class* machine.** The only large spare is **older, with less RAM**
  than fabricant — too weak to be the primary compute host or to carry the storage ARC.
- **That spare is the formerly-breached host** ([[fabricant-not-the-breached-host]] — the
  breach that drove this whole rebuild was never fabricant). It is currently
  **air-gapped**: forensics **complete**, all captured data **treated as suspect**, most
  (not yet all) of the original data rescued.
- **A small (8–16 GB) HA node is a *future* acquisition** — not yet owned; it will be
  bought and added **last** (possibly *after* the breached server returns). It is
  intended to sit in the **sealab subnet** and act as the **gateway between sealab and
  the internal VM plane**, in addition to carrying cluster quorum + critical-infra HA.
- **fabricant's rootfs is in a ZFS pool** — so its OS can be pivoted Proxmox → NixOS
  **without reformatting the data pools** (import them, don't migrate them).

**Scope:** only fabricant's Proxmox-hosted VMs (krg-prod, krg-ldap, krg-vault,
krg-deploy, e4e-prod). The physical NixOS hosts (waiter, kastner-ml) are already
bare-metal flake machines — out of scope. Tenants (fishsense, …) are *new* Incus
workloads (ADR 0017), not migrations.

## Decision

### 1. fabricant is the single strong NixOS+Incus host (storage + compute)

The hardware reality forbids splitting storage and compute across machines you don't
have. fabricant keeps the ZFS/NFS pools (`/home`, scratch) **and** runs the Incus
platform + operated instances — on one box. This is **no new SPOF**: fabricant is
already the sole hypervisor+storage host today. ARC is capped (the waiter pattern) so
the storage cache shares RAM with instances.

### 2. Pivot in place, rebuild-from-flake, no reformat

Because rootfs is in a ZFS pool and every VM is a flake config:

- **Surgically repave only the root dataset** (Proxmox → NixOS); `zpool import` the
  preserved data pools. **Never** `disko --mode destroy` the data pool — hand-import the
  data and let NixOS manage only the root. This is the one command that, wrong, wipes
  `/home`.
- **Re-instantiate each VM as an Incus instance from the flake**, pointing at the
  preserved data — not a disk-image lift-and-shift. The OS is reproducible and
  disposable; only data is precious.
- Bootloader PVE → NixOS-on-ZFS (the proven waiter pattern). **Snapshot + off-box backup
  of `/home` before the pivot** — "no reformat" ≠ "no backup."

### 3. The cluster grows to 3 nodes — incrementally, ending with the future small node

| Node | Hardware | When | Role |
|---|---|---|---|
| **fabricant** | strongest, holds the ZFS pools | first (pivot) | **primary** — storage (ZFS/NFS) + heavy compute (tenants, fishsense, operated instances) |
| **breached spare** | older, less RAM | after data-rescue + wipe | **secondary capacity** — medium/light instances; evacuation target for fabricant's pivot; interim home for critical-infra replicas (§5) |
| **small node** | 8–16 GB | **future / last** | **quorum voter + critical-infra HA + sealab↔VM-plane gateway** (§4) |

The 3-node end state arrives only when the small node is acquired; everything before it
runs in a deliberate **interim** (§4, §6).

### 4. The small node's three roles — and how the planes connect until it exists

The future small node is dual-homed (a leg in **sealab**, a leg in the **VM plane**) and
carries three lightweight, low-RAM-friendly roles: the **3rd dqlite voter** (§6), the
permanent home for **critical-infra HA** (second AD DC, OpenBao replica — app-level
replicas, not VM-failover), and the **sealab↔VM-plane gateway/chokepoint** (the
controlled L3 boundary + firewall between the lab's flat subnet and the internal NAT
plane).

**Until it's acquired**, those functions are covered interim, not skipped:
- **Plane connectivity:** fabricant's Incus **managed-NAT** provides VM-plane egress and
  the per-zone **edges** (krg-prod / e4e-prod, ADR 0017) provide service ingress, so
  sealab↔VM-plane works without the dedicated gateway. The small node later *formalizes*
  this into one isolated chokepoint.
- **Critical-infra HA:** to not let login-HA wait on a future box, the **second AD DC +
  OpenBao replica land on the cleaned breached spare** when it joins (it arrives before
  the small node), then move to / are joined by the small node when it lands. Until even
  the spare is clean, continuity is the existing posture — the SSSD offline cache + the
  local break-glass admin.

**Storage HA stays out of reach (be honest):** `/home` lives on fabricant's pools; no
small box can replicate it. `/home` *availability* rides on fabricant; the cleaned spare
serves as an off-box **ZFS-recv durability backstop** (recoverable, not live-failover).

### 5. Sequencing

1. **Now:** nested Incus on fabricant → fishsense + new tenants (ADR 0017). Old Proxmox
   VMs untouched; fabricant stays Proxmox. Single Incus node (no quorum concern).
2. **Breached-spare data-rescue → confidence → full wipe** (never trust the breached
   install; consider a firmware/BMC reflash) → clean-rebuild as a NixOS+Incus node. Data
   crosses as **suspect**: no credentials/keys/binaries forward, rotate. It joins as a
   **non-voter** (§6) and hosts the **interim critical-infra replicas**.
3. **Pivot fabricant** → NixOS+Incus, join the cluster. Either *windowed* (heavy services
   briefly down, login/secrets stay up on the spare's replicas) or *near-zero-downtime*
   (evacuate heavy VMs to the clean spare, repave, rejoin).
4. **[Future] acquire + join the small node** — last, possibly after the spare. It takes
   the **3rd quorum vote**, the **sealab↔VM-plane gateway**, and becomes the permanent
   home for critical-infra HA. Only now is the cluster fully quorate and the gateway
   dedicated.
5. **Rebalance:** heavy + storage on fabricant; medium/light on the spare; quorum +
   gateway + replicas on the small node. Proxmox retired.

### 6. Quorum — degraded until node 3, by design

Incus's dqlite wants **3 voters**. The small node *is* the 3rd voter, but it arrives
last, so the interim is run deliberately: **fabricant stays the sole voter** while the
cluster is 1–2 nodes (the cleaned spare joins as a **non-voter**), avoiding 2-node
split-brain at the cost of **no DB-HA until the small node lands**. Proper
single-failure-tolerant quorum is an *end-state* property, not an interim one — accepted.

### 7. Capacity governance is binding

The small node adds **negligible workload** capacity (replicas + vote + gateway), so
usable compute is ≈ fabricant + the weaker spare. ARC + operated instances + tenant
quotas + self-serve VMs must fit that. The **aggregate-capacity-governance** item
deferred in [ADR 0017](0017-incus-nat-self-serve-platform.md) is **no longer
deferrable** — it is the knob that stops self-serve from starving operated services and
the storage cache. Prefer **containers where trust allows**; keep **VM-tier quotas
tight**.

## Consequences

- **The 3-node end state (proper quorum, dedicated gateway, small-node-hosted
  critical-infra HA) lands last** — gated on a *future* acquisition. The interim runs
  degraded-but-functional: single voter, plane connectivity via fabricant + edges,
  critical-infra HA on the cleaned spare (or offline-cache/break-glass before that).
- **fabricant's pivot is decoupled from the small node** (the spare's replicas give
  identity/secrets continuity); the spare's cleanup gates only the *zero-downtime* path.
- **Foundational hosts (krg-ldap, krg-vault) migrate only behind their replicas** — never
  as singletons.
- **HA is app-level replicas, not VM-failover** (ZFS-local storage); **storage HA is out
  of scope**, with the spare as a `/home` durability backstop.
- **The breached host is reused only after a hard trust reset**; data suspect, nothing
  executable/credential-bearing crosses, secrets rotate; it joins last (before the small
  node).
- **waiter / kastner-ml unaffected** (physical flake hosts).
- **End state:** a 3-node NixOS+Incus cluster — fabricant (storage + heavy compute), the
  cleaned spare (secondary capacity + `/home` durability backstop), the small node
  (sealab↔VM-plane gateway + quorum + critical-infra HA); Proxmox retired; the hypervisor
  tier in the flake.

Related: [ADR 0004](0004-vm-disk-io-budget.md) (IO/ARC budget),
[ADR 0008](0008-e4e-prod-tenant-platform.md) (tenants),
[ADR 0009](0009-lab-internal-pki-ad.md) (PKI/AD — the DC/vault replicas),
[ADR 0011](0011-cross-layer-deploy-ordering.md) (deploy ordering),
[ADR 0015](0015-fleet-wide-container-logs-loki.md) (logs),
[ADR 0017](0017-incus-nat-self-serve-platform.md) (the platform; the edges + managed-NAT
that cover plane connectivity interim),
[ADR 0018](0018-monitoring-long-running-vms.md) (monitoring the result).
