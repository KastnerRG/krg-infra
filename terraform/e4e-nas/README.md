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

## Workloads

### Garage (S3 object store)

Single-node Garage on Container Manager, data on `/volume2/s3-data`, image
pinned (per ADR 0002 + 0003). Defined by:

- [`containers.tf`](containers.tf) `synology_container_project.garage` — uses the structured `services` attribute (NOT `content` — the provider's plan modifier silently rebuilds content from structured attrs, learned 2026-06-02)
- [`variables.tf`](variables.tf) — only `garage_image_tag` (pinned default)
- [`garage.toml.example`](garage.toml.example) — operator template for the config file (see below)

**Why no terraform-managed secrets**: the synology-community provider's nested
string attributes (`secrets.content`, `configs.content`) are not marked
sensitive in its schema — values leak verbatim in `tofu plan` / error output.
So Garage's secrets live in an operator-managed `garage.toml` file that this
resource only bind-mounts read-only into the container. Sub-PR 5 of #101
(garage_config Ansible role) supersedes the operator-managed step with
`no_log` + ansible-vault flow.

**Operator workflow — first deploy** (run this BEFORE `tofu apply` or the
container crash-loops on missing `/etc/garage.toml`):

```bash
# 1. On your laptop — fill in the 3 secrets in a local copy
cp terraform/e4e-nas/garage.toml.example /tmp/garage.toml
# Edit /tmp/garage.toml; replace REDACTED_RPC_SECRET / REDACTED_ADMIN_TOKEN /
# REDACTED_METRICS_TOKEN with `openssl rand -hex 32` outputs each. Save the
# three values to ~/.config/krg/secrets-garage.env (mode 0600) for recovery
# and for sub-PR 5 to consume.

# 2. scp to the NAS; root-owned, mode 0400; shred the laptop copy
scp /tmp/garage.toml e4e-admin@e4e-nas.ucsd.edu:/tmp/garage.toml
ssh e4e-admin@e4e-nas.ucsd.edu '
  sudo mkdir -p /volume1/docker/garage &&
  sudo install -o root -g root -m 0400 /tmp/garage.toml /volume1/docker/garage/garage.toml &&
  shred -u /tmp/garage.toml'
shred -u /tmp/garage.toml

# 3. Now apply
cd terraform/e4e-nas && tofu plan && tofu apply
```

**Operator workflow — cluster bootstrap** (one-shot AFTER first apply,
until #101 sub-PR 5 codifies):

`tofu apply` creates the project + starts the container, but the Garage
*cluster* is empty — no node has assigned capacity, no buckets exist. Run:

```bash
# 1. Get the node's short ID
NODE_ID=$(ssh e4e-admin@e4e-nas.ucsd.edu \
  'sudo docker exec garage garage status' \
  | awk '/HEALTHY/{print substr($1,1,16); exit}')

# 2. Assign capacity (single zone, sized to s3-data's free space)
ssh e4e-admin@e4e-nas.ucsd.edu \
  "sudo docker exec garage garage layout assign -z dc1 -c 5T $NODE_ID"

# 3. Commit the layout (bumps the layout version; required to take effect)
ssh e4e-admin@e4e-nas.ucsd.edu \
  'sudo docker exec garage garage layout apply --version 1'
```

After this the cluster is operational. Bucket + access-key management lives
in sub-PR 5 (the `garage_config` Ansible role reads
[`spec/e4e-nas/garage.yml`](../../spec/e4e-nas/garage.yml)). Sub-PR 4
(separate) adds DSM AppPortal reverse-proxy + Let's Encrypt for
`*.s3.garage.e4e-nas.ucsd.edu` + the admin/web endpoints.

## Shared source of truth

Like nix/ansible, this target can read the shared JSON files instead of
duplicating values, e.g. trusted nets for any firewall task driven through the
generic API resource (note the `../../` — this dir is two levels under the repo root):

```hcl
locals {
  trusted = jsondecode(file("${path.module}/../../nix/networks/trusted.json"))
}
```
