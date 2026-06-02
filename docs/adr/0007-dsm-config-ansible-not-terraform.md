# 0007. DSM config is Ansible, not Terraform — the split follows API surface, not appliance-ness

**Status:** Accepted · **Date:** 2026-06-01

## Context

The e4e-nas surface is managed across three layers (per ADR 0005):
[`terraform/e4e-nas/`](../../terraform/e4e-nas/) (OpenTofu), the
[`ansible/synology/`](../../ansible/synology/) roles, and the runbook
[`docs/e4e-nas-dsm.md`](../e4e-nas-dsm.md). A recurring, reasonable question:
*the NAS is configuration of an appliance — wouldn't most of it be cleaner as
Terraform?* Declarative, stateful, drift-detected — that's the Terraform pitch,
and "appliance config" sounds like its home turf.

It isn't, and the reason is worth recording so the question stops re-litigating.
The line between the layers is drawn by **what DSM actually exposes as an API**,
not by a tooling preference and not by how "appliance-like" the config feels.

## Decision

Keep the split as-is:

- **OpenTofu (`terraform/e4e-nas/`)** owns only what the community `synology`
  provider models as real resources: Container Manager, packages, scheduler,
  VMM. These have a clean Web-API → provider → state mapping. That is genuine
  Terraform with a meaningful drift model.
- **Ansible (`ansible/synology/`)** owns everything the provider does *not*
  model: shares, ACLs, SMB/NFS, users/groups, DSM web/system, security, AD join,
  snapshots, Hyper Backup. None of these has a Terraform resource — they have
  only DSM CLI/webapi tools (`synowebapi`, `synouser`, `synoshare`,
  `synoacltool`, …), which Ansible wraps idempotently (the `script:`+`raw`
  zero-prereq pattern, chosen because DSM's stock py3.8 is below Ansible's module
  floor).
- **The runbook (`docs/e4e-nas-dsm.md`)** owns the third bucket: settings with
  *neither* a provider *nor* a CLI that survives DSM updates (firewall, SSH,
  some snapshot/update settings) — UI-driven, by hand.

The governing rule:

> **Terraform for resources with a CRUD API and a meaningful drift model;
> Ansible for converging a no-API appliance via its CLI.** The "appliance-ness"
> does not pull config toward Terraform — the "API-ness" would, and DSM mostly
> lacks it.

## Why not force the no-API surface into Terraform

You *could* shell out from Terraform with `local-exec`. That is strictly worse
than the Ansible roles:

- **State that lies.** Terraform's value is a state file + drift detection over
  real CRUD resources. A `local-exec` running `synoacltool` is not a resource —
  nothing to read back, no reconciliation, just a command that ran once. You'd
  carry state that misrepresents reality.
- **Ordering.** Bring-up has a load-bearing imperative sequence enforced by the
  `synology_base` composer — `dsm_system → users → ssh → security →
  external_access → dsm_web → services → notifications → security_advisor →
  dsm_updates → ad` (**AD last** is the anti-lockout guarantee). Terraform's
  dependency graph fights this; you'd fake it with `depends_on` everywhere.
- **No dry run.** Ansible `--check --diff` previews against the live appliance
  (a documented bring-up gate). Terraform `plan` over `local-exec` previews
  nothing — it can't model a shell command's effect.
- **Decommission.** The Ansible subtree's teardown is `rm -rf ansible/synology/`,
  clean precisely *because* no state file entangles it. Terraform state over
  shell-outs is a liability you'd then have to migrate or destroy carefully.

DSM-without-an-API is **command-convergence** territory — run the CLI tools until
the box matches the declarative `spec/e4e-nas/*.yml` source of truth — which is
Ansible's home turf, not Terraform's.

## Consequences

- The three-layer split stays. New DSM config goes to Ansible **unless** the
  `synology` provider gains a real resource for it.
- **The split is provider-maturity-gated, not permanent.** If the community
  `synology` provider grows CRUD resources for shares/users/ACLs, moving *those*
  to OpenTofu would be genuinely cleaner (true declarative state + drift
  detection instead of imperative convergence). Re-evaluate when the provider
  advances; this ADR is the trigger to revisit, not a forever-no.
- Keeping the no-API surface in Ansible preserves the zero-prereq
  `script:`+`raw` choice (see related), which is intentionally tuned for DSM's
  py3.8 — a Terraform `local-exec` rewrite would discard that portability.

Related: ADR 0005 (repo integration / OpenTofu / the original split),
ADR 0001 (git as DSM source of truth), `docs/e4e-nas-dsm.md`,
the `synology_*` role READMEs under `ansible/synology/roles/`.
