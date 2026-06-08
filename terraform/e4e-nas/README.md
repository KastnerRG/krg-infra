# terraform/e4e-nas — Synology NAS (DSM)

One target of the [`terraform/`](../README.md) OpenTofu layer. Manages the
**Synology NAS `e4e-nas`** (`132.239.17.124`, DSM web on `:6021`) — already a
trusted host in [`../../nix/networks/trusted.json`](../../nix/networks/trusted.json)
and blackbox-probed by krg-prod's prometheus, but previously unmanaged.

This target has its **own state and credentials** — `tofu` from inside this dir:

```bash
cd terraform/e4e-nas
nix run nixpkgs#opentofu -- init      # or: tofu init
tofu validate
tofu plan
tofu apply
```

## Important: this is a hybrid, not full IaC

DSM is a proprietary appliance with **no first-class IaC story**. The community
provider (`synology-community/synology`) only exposes a *subset* of DSM:

| Managed here (Terraform) | NOT in the provider — see the runbook |
|---|---|
| Packages — `synology_core_package` (Container Manager) **[active]** | AD/LDAP domain join |
| File/folder provisioning — `synology_filestation_folder` **[active]** | Shared folders + ACLs |
| Container Manager projects (`synology_container_project`) † — *moved to Ansible* | SMB/NFS service settings |
| Scheduled tasks (`synology_core_event`) — *scaffolded/commented in `scheduler.tf`* | Users / groups, firewall, SSH |
| VMs (`synology_virtualization_*`) — *not yet used* | DSM update + snapshot/backup schedules |
| Generic `synology_api` escape hatch — *available, none defined yet* | |

† `synology_container_project` is modeled by the provider on paper, but the
implementation flunked the maturity test for Garage (3 distinct bugs in one
session: #110/#113/#114). Container workloads live in the
`synology_garage`-style Ansible roles until the resource matures — see
[ADR 0007](../../docs/adr/0007-dsm-config-ansible-not-terraform.md) "Garage
retreat" and the *Workloads → Garage* section below.

Everything in the right column — including the **identity** and **hardening**
work that matters most — lives in the runbook:
**[`../../docs/e4e-nas-dsm.md`](../../docs/e4e-nas-dsm.md)**. Those are DSM UI
settings that survive DSM updates (unlike SSH-level edits, which updates revert).

## Secrets & state

- Credentials: `terraform.tfvars` (gitignored) or `TF_VAR_*` env vars. Use a
  dedicated administrators-group account, **not** the built-in `admin`.
- **State is local for now and contains DSM secrets** — the top-level
  `terraform/.gitignore` keeps `*.tfstate` and `*.tfvars` out of git.
- Migrate state to a remote backend later (add a `backend` block to
  `versions.tf`, then `tofu init -migrate-state`). See [state encryption](../README.md#secrets--state-shared-rules).

## Workloads

### Garage (S3 object store)

Garage is **not managed from this terraform target**. The `synology-community/synology`
provider's `synology_container_project` resource hit three distinct upstream
bugs in one sitting on 2026-06-02 (#110 secrets-content-not-sensitive, #113
FileStation index instability, #114 JSON parser bombs on the docker-compose
streamed output) — which is the empirical signal [ADR 0007](../../docs/adr/0007-dsm-config-ansible-not-terraform.md)
anticipated for moving a surface to Ansible.

Deployment, `garage.toml` rendering, and cluster bootstrap (`layout assign` +
`apply`) all live in the `synology_garage` Ansible role under
[`../../ansible/synology/`](../../ansible/synology/); spec in
[`../../spec/e4e-nas/garage.yml`](../../spec/e4e-nas/garage.yml).

What *does* live here (containers.tf): three `synology_filestation_folder`
resources for `/docker/garage`, `/s3-data/meta`, `/s3-data/data`. DSM's
FileStation API only sees directories created through itself, so any
container workload bind-mounting these paths needs them index-registered.
The role can rely on the dirs existing without `sudo mkdir` workarounds.

> **Bring-up order:** the parent **shared folders** (`docker` on `/volume1`
> or wherever `spec/e4e-nas/shares.yml` puts it, and `s3-data` on
> `/volume2`) must exist before `tofu apply` here, or `FileStation.CreateFolder`
> errors with "path not found". Share creation is owned by the Ansible
> [`synology_shares`](../../ansible/synology/roles/synology_shares/) role
> driven from `spec/e4e-nas/shares.yml`. On a fresh NAS the canonical
> sequence is: Ansible `synology_shares` first → then this terraform
> target → then the Ansible `synology_garage` role.

## Shared source of truth

Like nix/ansible, this target can read the shared JSON files instead of
duplicating values, e.g. trusted nets for any firewall task driven through the
generic API resource (note the `../../` — this dir is two levels under the repo root):

```hcl
locals {
  trusted = jsondecode(file("${path.module}/../../nix/networks/trusted.json"))
}
```
