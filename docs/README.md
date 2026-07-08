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
| [kastner-ml-onboarding.md](kastner-ml-onboarding.md) | As-planned record + remote bring-up runbook for onboarding kastner-ml (GPU box, Ubuntu → NixOS + ZFS); destructive disk wipe gated on the end checklist |
| [onboarding-fishsense.md](onboarding-fishsense.md) | End-to-end runbook for fishsense — tenant #1 on the Incus platform (ADR 0017/0020): the repo-owned tenant declaration, the admin-provisioned boundary, and bring-up |
| [guacamole-temporal-consolidation.md](guacamole-temporal-consolidation.md) | One-time cutover folding the Guacamole + Temporal compose stacks into the single krg-prod compose project (they already shared the one openbao-agent) |
| [postgres-16-to-18-migration.md](postgres-16-to-18-migration.md) | Major-version upgrade of the krg-prod Postgres containers 16 → 18 (per-service data volumes, dump/restore) |

## Reference

| Doc | What it covers |
|---|---|
| [fleet-inventory.md](fleet-inventory.md) | Every host — IP, role, VMID, hypervisor — plus the Prometheus monitoring map |
| [waiter-topology.md](waiter-topology.md) | waiter storage (ZFS/impermanence) + network diagrams |
| [scratch-greenfield.md](scratch-greenfield.md) | waiter `/scratch` ZFS-native design (replaced autotier): pools/vdevs, the NFS overflow + `scratch-restore`, how to operate it |
| [fabricant-topology.md](fabricant-topology.md) | fabricant (Proxmox) storage + NFS + firewall diagrams |
| [krg-ldap-topology.md](krg-ldap-topology.md) | krg-ldap (AD DC) storage + network diagrams |
| [krg-prod-iac.md](krg-prod-iac.md) | How the krg-prod + e4e-nas IaC maps onto this repo's nix/ansible/terraform layers, and the NAS standup plan |
| [e4e-prod-tenant-platform.md](e4e-prod-tenant-platform.md) | The tenant-platform design record: edge TLS + OpenBao PKI + repo-owns-deploy. **Historical mechanism** — the sealed-microVM / `krg.tenants` interface it describes was superseded by the Incus/NAT platform + `lib.mkTenant` (ADR 0017/0020); [onboarding-fishsense.md](onboarding-fishsense.md) is the current runbook |
| [lab-interdependencies.md](lab-interdependencies.md) | How the layers depend on each other at deploy time (apply ordering) and at runtime (what breaks, how gracefully, when a component is down) |
| [monitoring.md](monitoring.md) | The Prometheus + Grafana + Loki + Blackbox stack on krg-prod (monitoring.krg.ucsd.edu) — scrape targets, IaC-managed datasources/SSO/dashboards |
| [fleet-mdm.md](fleet-mdm.md) | Self-hosted Fleet as the lab-owned MDM control plane (ADR 0012): FDE escrow, remote lock/wipe, update enforcement, config profiles for macOS/Windows/iOS/Android (NixOS excluded — the flake owns it) |
| [proxmox-auth.md](proxmox-auth.md) | How the PVE LDAP realm binds to the Authentik LDAP outpost (ADR 0014): `proxmox-admins` → Administrator, PAM break-glass |
| [pki-ad-integration.md](pki-ad-integration.md) | Wiring the OpenBao lab-internal CA into KRG.LOCAL so AD-group membership authorizes cert issuance, issued certs carry AD identity, and the CA is trusted fleet-wide |
| [vaultwarden-sso.md](vaultwarden-sso.md) | Vaultwarden (vaultwarden.krg.ucsd.edu) in the krg-prod compose stack with Authentik OIDC SSO — greenfield, no prior vaults migrated |
| [temporal-mtls.md](temporal-mtls.md) | Temporal frontend mTLS on krg-prod (validated on-box): cert render, mTLS `:7233`, plaintext internal-frontend bootstrap, UI client cert, no-cert rejection |

> Topology and monitoring diagrams are [Mermaid](https://mermaid.js.org/) and render
> inline on GitHub.

## Design notes & evaluations

Decision/analysis records that aren't operate-or-recover runbooks:

| Doc | What it covers |
|---|---|
| [scratch-architecture-options.md](scratch-architecture-options.md) | Historical: the `/scratch` redesign options (autotier symptoms, rejected brownfield, cost analysis); as-built is [scratch-greenfield.md](scratch-greenfield.md) |
| [e4e-nas-crowdsec-evaluation.md](e4e-nas-crowdsec-evaluation.md) | Why CrowdSec is **not** added to the NAS — DSM-native AutoBlock + Firewall + GeoIP instead |
| [label-studio-sso.md](label-studio-sso.md) | Label Studio Enterprise SSO (Authentik SAML) — re-attempt in progress (#326) after a prior vendor-side ACS 500 |

## Architecture Decision Records

Immutable decision records under [`adr/`](adr/). Mostly Accepted; 0015 is Proposed.

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
| [0009](adr/0009-lab-internal-pki-ad.md) | Lab-internal PKI is a private OpenBao CA hooked into AD — machines issue via AppRole, humans via AD-group-gated LDAP; CA trusted fleet-wide; separate from public Let's Encrypt |
| [0010](adr/0010-active-directory-structure-as-iac.md) | KRG.LOCAL AD structure (groups, service accounts, ACLs, password policy) is IaC in spec/krg-ad + ansible/krg-ad; apply is non-authoritative (adds, never deletes); humans come from roster |
| [0011](adr/0011-cross-layer-deploy-ordering.md) | Cross-layer deploy ordering: a phased pipeline (foundation → converge → verify), not a single linear order — back-edges between Ansible/NixOS/Tofu can't be solved by reordering |
| [0012](adr/0012-endpoint-device-management.md) | Endpoint device management is a lab-owned control plane, split Fleet (MDM for Windows/macOS/iOS/Android) + the flake (NixOS) — not solely campus Intune; FDE escrow + remote wipe on the lab's own timeline |
| [0013](adr/0013-sso-authentik-front-door.md) | SSO via Authentik is the front door, AD is the identity source — services federate (Authentik first, direct-AD fallback) rather than ship local accounts; lab members are AD users, web-only collaborators are minimal-trust Authentik-local accounts |
| [0014](adr/0014-proxmox-auth-ldap-outpost.md) | Proxmox VE authenticates via the Authentik LDAP outpost (not OIDC — Android app can't redirect; not raw AD — PVE won't expand nested groups / would clutter AD); the outpost flattens groups, PVE keys off `proxmox-admins` — narrowed to PVE-only by 0017 (Incus uses OIDC→Authentik direct) |
| [0015](adr/0015-fleet-wide-container-logs-loki.md) | **Proposed** — ship every host's container logs to Loki via a `journald` daemon log-driver + a per-host Alloy shipper, pushed over a Traefik/mTLS Loki endpoint; single-tenant with a `host`/`tenant` label |
| [0016](adr/0016-developed-apps-are-one-trust-tier.md) | Developed apps are one trust tier — audience ≠ trust; krg-prod is the trust root, not an app host (trust-axis correction stands; §3–§5 host-layout superseded by 0017) |
| [0017](adr/0017-incus-nat-self-serve-platform.md) | Re-realizes 0008: self-serve VMs + tenant services on an internal Incus/NAT platform behind per-zone edges; retires nested microVMs / `krg.tenants` (kept in reserve); ephemeral vs persistent tiers |
| [0018](adr/0018-monitoring-long-running-vms.md) | Monitoring follows persistence — agentless Incus `/1.0/metrics` + dynamic discovery for churning VMs; ephemeral get visibility-only, persistent get the full baseline |
| [0019](adr/0019-proxmox-to-incus-migration.md) | Migrate Proxmox → Incus with fabricant as the primary NixOS+Incus host (rootfs pivots in-place on ZFS), growing into a 3-node cluster with a future sealab HA/gateway node |
| [0020](adr/0020-tenant-deploy-contract-mktenant.md) | Tenant deploy contract — krg-infra exposes `lib.mkTenant` (+ `nixosModules.tenant`, a flake template) as a versioned API; tenant repos pin krg-infra and declare their deploy target, the typed realization of repo-owns-deploy |
