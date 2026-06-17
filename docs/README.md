# krg-infra docs

Operator-facing documentation for the KRG infrastructure. Architecture and
build/deploy basics live in the top-level [README](../README.md),
[nix/README](../nix/README.md), [ansible/README](../ansible/README.md), and
[CLAUDE.md](../CLAUDE.md); the runbooks and references here are the "how do I
actually operate / recover this" layer.

## Runbooks

| Doc | When you need it |
|---|---|
| [disaster-recovery.md](disaster-recovery.md) | Rebuild a host (or the whole fleet) from bare metal; what's reproducible vs. what must be restored from backup |
| [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) | One-time AD domain join (NixOS member / Debian / the DC) |
| [creating-a-user.md](creating-a-user.md) | Create a `KRG.LOCAL` account and grant it login / GPU access |
| [openbao-bringup.md](openbao-bringup.md) | Day-0 init / unseal / structure of OpenBao on krg-vault (prerequisite for the deploy + Garage runbooks) |
| [krg-deploy-ansible-setup.md](krg-deploy-ansible-setup.md) | Wire krg-deploy's unattended CD to pull NAS secrets from OpenBao via AppRole at apply time |
| [garage-ui-bringup.md](garage-ui-bringup.md) | One-time first deploy of the Garage S3 admin UI on e4e-nas from krg-deploy |
| [e4e-nas-dsm.md](e4e-nas-dsm.md) | e4e-nas break-glass + one-time migration sheet — the DSM settings with no API surface |
| [kerberos-long-jobs.md](kerberos-long-jobs.md) | Keep a long job / SMB mount authenticated past the Kerberos ticket lifetime (`krenew`, no keytab) |
| [working-remotely.md](working-remotely.md) | SSH from outside UCSD: strict-tier (UCSD + `ops`) vs compute-tier (global, CrowdSec-gated), and getting unbanned |
| [troubleshooting.md](troubleshooting.md) | Symptom-first recovery for the gotchas this fleet has hit (boot freeze, AD/login, scratch, ZFS) |

## Reference

| Doc | What it covers |
|---|---|
| [fleet-inventory.md](fleet-inventory.md) | Every host — IP, role, VMID, hypervisor — plus the Prometheus monitoring map |
| [waiter-topology.md](waiter-topology.md) | waiter storage (ZFS/impermanence) + network diagrams |
| [scratch-greenfield.md](scratch-greenfield.md) | waiter `/scratch` ZFS-native design (replaced autotier): pools/vdevs, the NFS overflow + `scratch-restore`, how to operate it |
| [fabricant-topology.md](fabricant-topology.md) | fabricant (Proxmox) storage + NFS + firewall diagrams |
| [krg-ldap-topology.md](krg-ldap-topology.md) | krg-ldap (AD DC) storage + network diagrams |
| [krg-prod-iac.md](krg-prod-iac.md) | How the krg-prod + e4e-nas IaC maps onto this repo's nix/ansible/terraform layers, and the NAS standup plan |
| [e4e-prod-tenant-platform.md](e4e-prod-tenant-platform.md) | e4e-prod multi-tenant platform for student-built projects: sealed microVM per tenant, edge TLS + OpenBao PKI, the `krg.tenants` interface, onboarding |

> Topology and monitoring diagrams are [Mermaid](https://mermaid.js.org/) and render
> inline on GitHub.

## Design notes & evaluations

Decision/analysis records that aren't operate-or-recover runbooks:

| Doc | What it covers |
|---|---|
| [scratch-architecture-options.md](scratch-architecture-options.md) | Historical: the `/scratch` redesign options (autotier symptoms, rejected brownfield, cost analysis); as-built is [scratch-greenfield.md](scratch-greenfield.md) |
| [e4e-nas-crowdsec-evaluation.md](e4e-nas-crowdsec-evaluation.md) | Why CrowdSec is **not** added to the NAS — DSM-native AutoBlock + Firewall + GeoIP instead |

## Architecture Decision Records

Immutable decision records under [`adr/`](adr/). All Accepted.

| ADR | Decision |
|---|---|
| [0001](adr/0001-iac-source-of-truth.md) | Git is the single source of truth for krg-prod + e4e-nas; UI/by-hand changes are drift to be reconciled, not blessed |
| [0002](adr/0002-garage-not-minio.md) | Use Garage (not MinIO) for S3 object storage |
| [0003](adr/0003-garage-on-nas-not-vm.md) | Garage runs on the NAS (dedicated storage), not the IO-budgeted krg-prod VM — deployment mechanism later amended by 0007 |
| [0004](adr/0004-vm-disk-io-budget.md) | The krg-prod VM operates under a disk-IO budget — only low-IO workloads belong on it |
| [0005](adr/0005-repo-integration-opentofu-krg-deploy.md) | krg-prod IaC integrates into this repo; OpenTofu over Terraform; krg-deploy is the control node |
| [0006](adr/0006-no-oec-on-dsm.md) | No Qualys/Trellix (OEC) on DSM — DSM-native Security Advisor replaces it |
| [0007](adr/0007-dsm-config-ansible-not-terraform.md) | The DSM tofu/ansible split follows API surface (real provider resources vs CLI-only), not "appliance-ness" |
| [0008](adr/0008-e4e-prod-tenant-platform.md) | e4e-prod is a multi-tenant platform for student-built projects — sealed microVM per tenant, repo-owned deploys, LE-terminate-then-re-encrypt edge |
