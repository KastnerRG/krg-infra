# 0001. Git is the source of truth for krg-prod; UI changes are drift

**Status:** Accepted · **Date:** 2026-05-22

## Context

`krg-prod` spans two managed hosts: the Synology **e4e-nas** (DS3617xs, DSM 7.3)
and the **krg-prod NixOS VM** on Proxmox. The wider repo goal is to be able to burn
the infrastructure down and stand it back up from code (see the project's
burn-down-and-rebuild north star). DSM in particular invites click-ops, and
click-ops is how config silently drifts from intent.

## Decision

The **git repo is the single source of truth** for both hosts. There is **no
"documented manual runbook" workflow** — a change made in the DSM UI (or by hand on
the VM) is treated as **drift**: detected, alerted, and reconciled back to the repo,
not blessed after the fact. The break-glass runbook (`docs/runbook.md` /
`docs/e4e-nas-dsm.md`) exists **only** for recovery when automation can't run.

This is a deliberate, accepted trade: IaC is harder up front than a runbook. We are
not redesigning around that difficulty.

## Consequences

- Requires the drift-detection machinery to be real, not aspirational: the Ansible
  state-path exporter (`drift_exporter`) **and** the Loki audit-log actor-path
  detector, with alerts.
- Requires **UI lockdown** (DSM password login disabled for humans; automation via
  API token; SSH-key break-glass; read-only human DSM accounts) — see ADR 0001's
  enforcement in the IaC plan.
- Requires a **test rig** (XPEnology DSM in libvirt) so changes are validated before
  they touch prod.
- Higher initial cost (multi-day). Accepted.

Related: ADR 0005 (how this is structured in the repo), `docs/krg-prod-iac.md`.
