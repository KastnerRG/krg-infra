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
| **Authentik** (`krg-authentik`) | SSO app: HTTP req rate/latency, flow executions, system tasks, runtime | `authentik_*`, `go_*` |
| **Temporal** (`krg-temporal`) | Workflow engine: gRPC req/error rate + latency, persistence latency, runtime | `service_*`, `persistence_*`, `go_*` |
| **Loki** (`krg-loki`) | Log store self-metrics: ingest bytes/lines, request latency, chunk flushes | `loki_*`, `go_*` |
| **Grafana** (`krg-grafana`) | Grafana self: HTTP req/latency, datasource proxy, DB connections, runtime | `grafana_*`, `go_*` |
| **Logs** (`krg-logs`) | **LogQL** log content: volume by job, error/warn rate, live log panels | Loki datasource (`krg-loki-ds`) |

> The **Logs** dashboard queries the **Loki** datasource (`krg-loki-ds`, `datasources.tf`),
> not Prometheus — it surfaces log *content* that Alloy ships to Loki. The **Loki**
> dashboard above is Loki's own Prometheus *metrics*. Authentik/Temporal/Loki/Grafana
> metric names should be confirmed against the live endpoints once deployed (versions
> shift names; a "No data" panel just needs a query tweak, not a redeploy).

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
| `temporal` | 8000 | temporal | Temporal server metrics (now an in-repo compose service, `compose.temporal.yml`). |
| `loki` | 3100 | loki | Loki self-metrics, over the krg-prod default network. |
| `grafana` | 3000 | grafana | Grafana self-metrics. |
| `authentik` | 9300 | authentik_server, authentik_worker | Joined `prometheus_network` (`compose.authentik.yml`) so :9300 is reachable. |

`node_zfs_*` (ARC/L2ARC) requires the node_exporter **`zfs`** collector, enabled
only on **waiter** (`nix/hosts/waiter/default.nix`). Pool health everywhere comes
from the `zpool_health` textfile metric (`nix/modules/zfs.nix`).

## Known gaps (tracked as `area:monitoring` issues)

Now covered (scrape job + dashboard added in the convergence PR): **Grafana**,
**Loki** self-metrics, **Authentik** (`:9300`, joined `prometheus_network`),
**Temporal**, and **log content** (Loki datasource + the `krg-logs` dashboard —
previously logs were shipped to Loki by Alloy but had no datasource, so were
invisible in Grafana).

Remaining gaps — still blocked on an exporter we don't run yet:

- **PostgreSQL** (Authentik, Guacamole, Temporal, Outline DBs) — needs a
  `postgres_exporter` sidecar per DB (+ a read-only monitoring role) before a
  dashboard works. **Deferred** to a follow-up: it's an exporter fleet, not a
  dashboard. Once those land, add `dashboards/postgres.json` with a `$instance`
  picker over `pg_up`.
- **Per-container** CPU/mem/net — `docker_exporter` is engine-level; needs cAdvisor.
- **SMART** disk health on waiter — `smartd` runs (alerts only); no Prometheus metrics, despite the no-redundancy striped `scratchpool`.
- **Guacamole / Vaultwarden** — no native Prometheus endpoint; coverage is indirect
  via the Traefik (ingress) + Uptime (blackbox) dashboards, plus the future Postgres
  dashboard for Guacamole's DB.
- **Stale targets** — `localhost:9290` (dead BMC on a VM) and the external `temporal:8000` job still want an audit (#161). `kastner-ml` is no longer stale: it's now a real flake host (#223).

## Adding a dashboard

1. Add `terraform/grafana/dashboards/<name>.json` (Grafana JSON, schemaVersion 42).
   Reference the datasource as `{"type":"prometheus","uid":"de0e1fh1fk35sc"}`.
2. `tofu plan` / `tofu apply` in `terraform/grafana/` — `dashboards.tf` picks it up.

Use templated `$instance` variables (`label_values(...)`) for fleet dashboards so
one dashboard covers every host of a kind, rather than one-dashboard-per-host.
