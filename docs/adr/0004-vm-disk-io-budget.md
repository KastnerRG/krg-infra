# 0004. The krg-prod VM has a disk-IO budget

**Status:** Accepted · **Date:** 2026-05-22

## Context

The Proxmox host backing the krg-prod NixOS VM shares its storage between the VM's
virtual disk and the **NFS home directories serving a GPU server**. Disk-IO-heavy
workloads on the VM would degrade latency-sensitive interactive work on the GPU
server.

## Decision

The krg-prod VM operates under a **disk-IO budget**. Only **low-IO workloads** belong
on it: the monitoring stack (Prometheus/Grafana/Loki/Promtail/Alertmanager) and the
`drift_exporter`. **Any future addition must clear this bar** explicitly.

VM hardening reinforces the budget: **no swap**, Docker log driver set to **journald
with explicit rotation**, and **per-container CPU/memory limits** in the compose file.

## Consequences

- IO-heavy services go to the NAS (e.g. Garage — ADR 0003) or elsewhere, never the VM.
- "Does it fit the IO budget?" is a required review question for anything new on the VM.

Related: ADR 0003.
