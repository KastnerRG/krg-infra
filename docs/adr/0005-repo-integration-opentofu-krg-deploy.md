# 0005. krg-prod IaC integrates into this repo; OpenTofu; krg-deploy is the control node

**Status:** Accepted · **Date:** 2026-05-22

## Context

The krg-prod IaC architecture was specced without sight of this repo
(`krg-nixos-flakes`), which already has the relevant bones: a `nix/` flake managing
the krg-prod VM, a `compose-stack` module (systemd-wraps-`docker compose`), a
krg-prod monitoring compose, a `terraform/` (OpenTofu) per-target scaffold, and an
`ansible/` layer. Standing up a parallel repo would discard working pieces.

## Decision

- **Integrate, don't fork:** the krg-prod IaC lives **in this repo**, reusing its
  modules and structure. Honor the repo invariant **one host = one config tool**.
- **OpenTofu**, not HashiCorp Terraform (FOSS, in nixpkgs, provenance).
- **NAS management split:**
  - **OpenTofu** (`terraform/e4e-nas/`) — what the `synology` provider covers:
    shared folders, Container Manager (Garage), VMM, file uploads.
  - **Ansible** (`ansible/synology/roles/synology_*`, a `synology` inventory group with host
    `e4e-nas`) — everything the provider can't reach: ACLs, NFS exports, SMB globals,
    snapshot/scrub schedules, SSH keys, firewall, packages, users/groups. Roles wrap
    DSM CLI (`synouser`, `synogroup`, `synoshare`, `synoacltool`, `synoservicectl`,
    `synopkg`, `synosetkeyvalue`) idempotently, each with a paired `--check` exporter.
  - **`spec/e4e-nas/*.yml`** — declarative source of truth (users, groups, shares,
    acls, nfs-exports, smb-globals, garage), consumed by the Ansible roles. Seeded
    from the e4e-nas build sheet in `docs/e4e-nas-dsm.md`.
- **VM management:** the **`nix/` flake** (host `krg-prod`); the VM is **not** in the
  Ansible inventory.
- **Deploy + state:** **`krg-deploy`** is the single deploy control node — it runs
  `tofu`, `ansible-playbook`, and `nixos-rebuild … --target-host`. OpenTofu **state
  lives on/with krg-deploy**, with **state encryption + a backup**. A single deployer
  means no concurrent applies, so no remote-lock backend is required. State must
  **not** live on the NAS, nor in the Garage that OpenTofu deploys (circular).
  **Until krg-deploy exists, state stays local and migrates to it later.**

## Consequences

- Reuse: `compose-stack` module, the existing monitoring compose, `terraform/e4e-nas/`,
  and the Ansible `monitoring` role (already provides the Proxmox-host node_exporter
  scrape target).
- OpenTofu keeps the per-target root-module convention (`terraform/e4e-nas/` is the
  target), not one flat root.
- CI and the `nix develop` shell pin OpenTofu, not Terraform.
- `krg-deploy` itself becomes a host to define and harden (future).

Related: ADR 0001, `docs/krg-prod-iac.md`.
