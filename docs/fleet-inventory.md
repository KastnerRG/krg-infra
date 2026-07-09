# Fleet inventory & monitoring map

Canonical list of every machine in the KRG infrastructure — IP, role, config
layer, and (for VMs) hypervisor + VMID — plus how monitoring is wired. IPs are
otherwise scattered across [`nix/networks/trusted.json`](../nix/networks/trusted.json)
comments and per-host configs; this is the one table to update when they change.

> **Related:** topology diagrams for [waiter](waiter-topology.md) ·
> [fabricant](fabricant-topology.md) · [krg-ldap](krg-ldap-topology.md).

## Hosts

| Host | IP | FQDN | Role | Config layer | Hypervisor / kind | VMID |
|---|---|---|---|---|---|---|
| **fabricant** | 137.110.161.98 | fabricant.ucsd.edu | Proxmox VE **9** hypervisor; NFS server | Ansible (`proxmox`) | physical | — |
| **waiter** | 137.110.161.67 | waiter.ucsd.edu | GPU/FPGA compute (`compute` profile) | NixOS flake | physical | — |
| **krg-ldap** | 137.110.161.109 | krg-ldap.ucsd.edu | Samba AD DC, `KRG.LOCAL` (`directory`) | NixOS flake | VM on fabricant | 100 |
| **krg-vault** | 137.110.161.123 | krg-vault.ucsd.edu | OpenBao secrets manager (`base`) | NixOS flake | VM on fabricant | 101 |
| **krg-deploy** | 137.110.161.122 | krg-deploy.ucsd.edu | Ansible + OpenTofu control node; GitHub Actions deploy runner (`base`) | NixOS flake | VM on fabricant | 102 |
| **krg-prod** | 137.110.161.106 | krg-prod.ucsd.edu | Lab-wide services (`server` profile) | NixOS flake | VM on fabricant | 103 |
| **e4e-prod** | 137.110.161.107 | e4e-prod.ucsd.edu | `*.e4e` public edge (Traefik LE-terminate → re-encrypt), E4E services (`server`) | NixOS flake | VM on fabricant | 104 |
| **krg-nat** | 137.110.161.105 | krg-nat.ucsd.edu | Incus platform host / hypervisor for tenant instances on the NAT ([ADR 0017](adr/0017-incus-nat-self-serve-platform.md)) | NixOS flake | VM on fabricant | 105 |
| **kastner-ml** | 132.239.17.123 | kastner-ml.ucsd.edu | E4E GPU compute, RTX A6000 (`compute` profile) | NixOS flake | physical | — |
| **e4e-nas** | 132.239.17.124 | e4e-nas.ucsd.edu | Synology NAS (krg-prod storage) | (separate IaC effort) | appliance | — |

> The old `krg-ad` host (breached, decommissioned) is gone; its address
> **137.110.161.107** is now reused by **e4e-prod**.

Other fixed addresses:

| Thing | Value | Where |
|---|---|---|
| Default gateway | 137.110.161.1 | every host's `networking.defaultGateway` |
| Monitoring host (Prometheus) | 137.110.161.106 (krg-prod) | `trusted.json` `monitoring_host` |
| AD DNS / KDC | 137.110.161.109 (krg-ldap) | `krg.adClient.serverIp`; pinned in `/etc/hosts` |
| Site DNS fallbacks | 132.239.0.252, 8.8.8.8, 1.1.1.1 | host `networking.nameservers` (after the DC) |
| Ops admin IPs (off-campus) | 97.170.130.76 (chris), 107.132.34.148 (sean) | `trusted.json` `ipsets.ops` |

> All VM hosts now pin their static IPs in their host `default.nix` (krg-prod,
> e4e-prod, krg-nat, krg-vault, krg-deploy) and have assigned VMIDs on fabricant.

## Trusted-network IPSets

Defined once in [`trusted.json`](../nix/networks/trusted.json), consumed by both
layers (nix `krg.firewall`, Ansible `proxmox_firewall` cluster.fw, CrowdSec
whitelists). Summary:

| IPSet | Contents | Used for |
|---|---|---|
| `public` | `0.0.0.0/1` + `128.0.0.0/1` (the whole internet) | compute SSH |
| `sealab` | Sealab wifi `132.239.10.0/24`, e4e-nas, krg-prod, e4e-prod, krg-ldap, kastner-ml | DC↔member SMB/RPC; CrowdSec whitelist |
| `ucsd` | `100.0.0.0/8`, `128.54.0.0/16`, `137.110.0.0/16`, + sealab hosts | service SSH, PVE UI, AD client ports |
| `ops` | off-campus admin IPs (chris, sean) | SSH + PVE UI from off-campus |
| `machines` | fleet domain members (waiter, fabricant, krg-prod, krg-ldap, krg-deploy, krg-vault, krg-nat, kastner-ml) | inter-host trust; CrowdSec whitelist; OpenBao `:8200` source |

## Monitoring map

Prometheus runs on **krg-prod** (Docker compose stack) and scrapes exporters
across the fleet. Each host's in-guest firewall opens the exporter ports **only
to the monitoring host** (`krg.firewall.monitoringPorts` ← `monitoringSourceIp`);
on Proxmox hosts the same restriction is in `cluster.fw`.

```mermaid
flowchart LR
  subgraph prod["krg-prod 137.110.161.106 — monitoring stack (Docker)"]
    direction TB
    prom["Prometheus"]
    graf["Grafana"]
    loki["Loki + Alloy<br/>(planned fleet-wide)"]
    bb["Blackbox exporter<br/>(HTTP/ICMP probes)"]
    prom --> graf
    loki --> graf
  end

  waiter[("waiter<br/>node :9100 · ipmi :9290<br/>docker :9323 · DCGM :9400")]
  kml[("kastner-ml<br/>node :9100<br/>docker :9323 · DCGM :9400")]
  fab[("fabricant<br/>node :9100 · ipmi :9290")]
  ldap[("krg-ldap<br/>node :9100")]

  prom -->|"scrape (pull)"| waiter
  prom -->|"scrape (pull)"| kml
  prom -->|"scrape (pull)"| fab
  prom -->|"scrape (pull)"| ldap
  bb -.->|"probe HTTP/ICMP"| ext(("lab & E4E websites,<br/>1.1.1.1, 8.8.8.8"))
```

### Exporters by host

| Exporter | Port | Source | Hosts | Notes |
|---|---|---|---|---|
| node_exporter | 9100 | native systemd (nix) / systemd (ansible) | all | + ZFS pool-health textfile collector ([`zfs.nix`](../nix/modules/zfs.nix)) |
| ipmi_exporter | 9290 | native systemd | waiter, fabricant | compute + hypervisor (krg-prod is a VM → off) |
| DCGM exporter | 9400 | Docker (CDI GPU) | waiter, kastner-ml | coupled to the NVIDIA driver ([`nvidia.nix`](../nix/modules/hardware/nvidia.nix)) |
| docker metrics | 9323 | dockerd | waiter, kastner-ml | Docker daemon metrics endpoint |

> **Prometheus scrape config** [`prometheus.yml`](../nix/docker-compose/krg-prod/prometheus/prometheus.yml)
> now targets the renamed hosts (`krg-prod.ucsd.edu`, etc.) per the machine/CNAME
> rename plan. The dead `ansible_deploy_monitor` `:9000` job has been dropped
> (replaced by `system.autoUpgrade`), and `kastner-ml.ucsd.edu` is now a real
> provisioned fleet host (issue #223) scraped for node/dcgm/docker metrics — no
> longer an unmanaged leftover. Blackbox probe targets (E4E/lab websites) track the
> new CNAMEs. **krg-vault** and **krg-deploy** also expose node-exporter `:9100`
> (monitoring-host only) but are not yet in the `node_exporter` scrape job — add them
> when convenient.
