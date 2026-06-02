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
| Container Manager projects (`synology_container_project`) | AD/LDAP domain join |
| Packages (`synology_core_package`) | Shared folders + ACLs |
| Scheduled tasks (`synology_core_event`) | SMB/NFS service settings |
| File/folder provisioning (`synology_filestation_*`) | Users / groups, firewall, SSH |
| VMs (`synology_virtualization_*`) | DSM update + snapshot/backup schedules |
| Generic `synology_api` escape hatch (any DSM Web API) | |

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

## Shared source of truth

Like nix/ansible, this target can read the shared JSON files instead of
duplicating values, e.g. trusted nets for any firewall task driven through the
generic API resource (note the `../../` — this dir is two levels under the repo root):

```hcl
locals {
  trusted = jsondecode(file("${path.module}/../../nix/networks/trusted.json"))
}
```
