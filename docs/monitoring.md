# Monitoring (Prometheus + Grafana)

The lab-wide monitoring stack runs as Docker Compose on **krg-prod**
(`nix/docker-compose/krg-prod/`): Prometheus (scrape + TSDB), Grafana
(visualisation, Authentik SSO), Loki/Promtail (logs), and the Blackbox exporter
(synthetic probes). Grafana is served at **monitoring.krg.ucsd.edu**.

Grafana's datasources, SSO, and **dashboards** are managed as code in
`terraform/grafana/` (OpenTofu). This doc is the map of *what is monitored* and
*what dashboards exist*.

## Dashboards

Authored as raw Grafana JSON under `terraform/grafana/dashboards/` and applied by
`dashboards.tf` (a single `for_each` over `*.json` — drop a new file in and it's
picked up). Every panel targets the Prometheus datasource by its pinned UID
(`de0e1fh1fk35sc`, set in `datasources.tf`).

| Dashboard (UID) | Scope | Source metrics |
|---|---|---|
| **Waiter** (`ee0e2rvzbh2wwf`) | Bespoke deep-dive for the compute host: CPU/mem/GPU **and** the ZFS scratch stack (pool health, ARC/L2ARC, per-mount capacity, NVMe temps), systemd-failure + exporter-up health | node + DCGM + `zpool_health` + `node_zfs_*` |
| **Node Fleet** (`krg-node-fleet`) | All `node_exporter` hosts (CPU/mem/disk/net/fs), `$instance` picker | `node_*` |
| **GPU (DCGM)** (`krg-gpu-dcgm`) | All GPU hosts: util, framebuffer, temp, power, clocks, XID/ECC/PCIe health | `DCGM_FI_DEV_*` |
| **Traefik** (`krg-traefik`) | Ingress: req rate by service/code/entrypoint, p50/p95/p99 latency, TLS expiry | `traefik_*` |
| **Uptime & Probes** (`krg-uptime`) | Blackbox HTTP + ICMP: availability timelines, latency, TLS cert expiry | `probe_*` |
| **IPMI / BMC** (`krg-ipmi`) | Physical hosts' out-of-band sensors: temp, fan, voltage, power | `ipmi_*` |
| **Docker Engine** (`krg-docker-engine`) | Docker daemon built-in metrics (engine-level only) | `engine_daemon_*` |
| **Monitoring Health** (`krg-monitoring-health`) | Self-monitoring: target up/down, scrape duration, TSDB stats | `up`, `scrape_*`, `prometheus_*` |

## Scrape inventory

Source of truth: `nix/docker-compose/krg-prod/prometheus/prometheus.yml`.

| Job | Port | Targets | Notes |
|---|---|---|---|
| `node_exporter` | 9100 | waiter, kastner-ml, fabricant, krg-prod, e4e-prod, krg-ldap, krg-vault | On every NixOS host (`profiles/base.nix`) + fabricant (ansible). |
| `dcgm_exporter` | 9400 | waiter, kastner-ml | NVIDIA GPUs. |
| `docker_exporter` | 9323 | waiter, kastner-ml | Docker daemon `--metrics-addr`; **engine-level only**, no per-container stats. |
| `ipmi_exporter` | 9290 | waiter, fabricant (+ localhost, dead) | Physical hosts only; VMs have no BMC. |
| `traefik` | 8082 | traefik:8082 | Scraped over the `traefik_proxy` docker network; metrics on a dedicated unpublished entrypoint. |
| `prometheus` | 9090 | localhost | Self-scrape. |
| `blackbox_exporter` / `website_monitoring` / `blackbox-ping` | 9115 | exporter + HTTP/ICMP targets | Synthetic probes. |
| `octoprint` | 80 | e4e-octopi | 3D-printer exporter. |
| `temporal` | 8000 | fishsense-temporal | **External** — container not defined in this repo. |

`node_zfs_*` (ARC/L2ARC) requires the node_exporter **`zfs`** collector, enabled
only on **waiter** (`nix/hosts/waiter/default.nix`). Pool health everywhere comes
from the `zpool_health` textfile metric (`nix/modules/zfs.nix`).

## Known gaps (tracked as `area:monitoring` issues)

These services run but expose no metrics to Prometheus yet — dashboards for them
are blocked on a scrape job (and sometimes an exporter):

- **Grafana** `/metrics` — not scraped (exposes natively).
- **Loki + Promtail** — expose metrics (3100 / 9080) but aren't scraped.
- **PostgreSQL** (Authentik, Outline) — no `postgres_exporter`.
- **Per-container** CPU/mem/net — `docker_exporter` is engine-level; needs cAdvisor.
- **SMART** disk health on waiter — `smartd` runs (alerts only); no Prometheus metrics, despite the no-redundancy striped `scratchpool`.
- **Authentik** — evaluate its Prometheus metrics endpoint.
- **Stale/external targets** — `temporal` (external), `kastner-ml` (not in this flake), `localhost:9290` (dead) want an audit.

## Adding a dashboard

1. Add `terraform/grafana/dashboards/<name>.json` (Grafana JSON, schemaVersion 42).
   Reference the datasource as `{"type":"prometheus","uid":"de0e1fh1fk35sc"}`.
2. `tofu plan` / `tofu apply` in `terraform/grafana/` — `dashboards.tf` picks it up.

Use templated `$instance` variables (`label_values(...)`) for fleet dashboards so
one dashboard covers every host of a kind, rather than one-dashboard-per-host.
