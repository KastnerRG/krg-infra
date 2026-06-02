# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

`krg-infra` is the KastnerRG infrastructure monorepo, replacing the old Ansible
infrastructure at [fabricant-prod](https://github.com/KastnerRG/fabricant-prod)
and [waiter](https://github.com/KastnerRG/waiter). Layers are split by
configuration tool (not by guest/host role — some NixOS machines are physical):

- **`nix/`** — every machine configured by **NixOS** (the flake): physical hosts
  (waiter) *and* Proxmox VMs (krg-prod, e4e-prod, krg-ldap). Machines are composed
  from profile modules — no per-host playbooks.
- **`ansible/`** — the **Proxmox/Debian hypervisor hosts** those VMs run on.
- **`terraform/`** — the **OpenTofu layer**: things driven through a Terraform/
  Web-API provider rather than NixOS or Ansible. **One root module (own state +
  creds) per target** — not one combined config (separate blast radius). Targets:
  `e4e-nas/` (Synology DSM, built), `authentik/` (SSO config, planned),
  `vault/` (secrets-engine structure, planned). `authentik/` + `vault/` manage the
  *config of* services deployed elsewhere (Authentik = compose on krg-prod; Vault =
  future), not their deployment. e4e-nas is a *hybrid*: the `synology` provider only
  covers Container Manager / packages / tasks / files / VMs; identity (AD join),
  shares/ACLs, firewall, SSH, snapshots and DSM updates have no API and live in the
  runbook `docs/e4e-nas-dsm.md` (DSM is a proprietary appliance — SSH-level edits
  don't survive DSM updates, so prefer UI settings).

This whole rebuild is incident-response driven: a Proxmox host's root SSH was
dictionary-attacked. The hypervisors had no config management — `ansible/` closes
that gap (secure + up to date by default), and the old AD (inside the blast
radius) is being rebuilt clean as a new Samba AD forest on krg-ldap.

**Target feature set (from the old Ansible repos):**
- **fabricant-prod**: production services — Traefik, Authentik (SSO), Grafana/Prometheus/Loki, Blackbox, PostgreSQL, Outline, MLflow, Label Studio, node/IPMI exporters, firewall, unattended upgrades. (These are the lab-wide tools now on **krg-prod**; E4E project-specific services go on **e4e-prod**.)
- **waiter**: research/compute at 137.110.161.67 — NVIDIA CUDA + Container Toolkit, FPGA tooling (Vivado, Vitis, Verilator; opt-in), XRDP+XFCE desktop (opt-in, gated on FPGA), Fail2ban, native node/IPMI exporters + DCGM exporter (Docker) — blackbox now lives on krg-prod — and **ZFS-on-root** with ZFS auto-snapshots (replacing the old btrfs/snapper). The legacy Ubuntu setup used btrfs + Docker-based node/blackbox; the rebuild moved those to the patterns above.

## Common Commands

The flake lives in `nix/`. Run from the repo root with the `./nix` ref shown
below, or `cd nix` and drop the prefix.

```bash
# Validate the flake (Nix syntax + module type checking)
nix flake check ./nix

# Build a system config without deploying
nix build ./nix#nixosConfigurations.krg-prod.config.system.build.toplevel
nix build ./nix#nixosConfigurations.waiter.config.system.build.toplevel

# Inspect a config value
nix eval ./nix#nixosConfigurations.krg-prod.config.networking.hostName

# Deploy to the current machine
sudo nixos-rebuild switch --flake ./nix#krg-prod

# Deploy remotely (new nixos-rebuild: --sudo, not --use-remote-sudo)
nixos-rebuild switch --flake ./nix#krg-prod --target-host krg-admin@krg-prod.ucsd.edu --sudo --ask-sudo-password
nixos-rebuild switch --flake ./nix#waiter   --target-host krg-admin@137.110.161.67 --sudo --ask-sudo-password

# Update flake inputs (run inside nix/)
cd nix && nix flake update          # or: nix flake update nixpkgs

# Format .nix files
alejandra nix    # or: nixfmt nix

# --- Proxmox hosts (ansible/) ---
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml --check     # dry run
ansible-playbook playbooks/site.yml
```

## Repository Structure

```
krg-infra/
  CLAUDE.md  README.md  LICENSE  .github/workflows/build.yml
  nix/                             # NixOS machines (physical + Proxmox guests)
    flake.nix                      # inputs + nixosConfigurations (krg-prod, e4e-prod, waiter, krg-ldap)
    keys/admins.json               # SHARED admin SSH keys — read by nix + ansible
    networks/trusted.json          # SHARED trusted nets / Proxmox IPSets — read by nix + ansible + PVE cluster.fw
    modules/
      docker.nix  users.nix  nix-ld.nix  impermanence.nix
      zfs.nix                      # ZFS support + auto-scrub + auto-snapshot retention (krg.zfs); WHICH datasets/cadence is per-dataset via com.sun:auto-snapshot props. NixOS hosts run the timers; fabricant (Proxmox) runs the same tool via ansible nfs_server
      nfs-home.nix                 # mount /home from NFS (krg.nfsHome) — AD user homes off the local ZFS root (enables impermanence)
      scratch.nix  scratch/        # /scratch/<lab> on PLAIN ZFS (krg.scratch) — scratchpool (striped HDD + NVMe special/L2ARC); daily cold-file overflow to NFS + self-service scratch-restore (modules/scratch/*.py). Replaced autotier (FUSE; crashed under concurrent training reads)
      local-cache.nix              # node-local /local/<user> (krg.localCache) — IDE servers + cache class OFF the NFS /home (durable NVMe dataset, no FUSE/NFS)
      samba-ad.nix                 # Samba AD domain controller (samba4Full daemon, krb5.conf, DNS/resolver, AD ports)
      sssd-ad-client.nix           # SSSD AD client (krg.adClient) — every host joins KRG.LOCAL; key-only SSH with keys served from AD (sss_ssh_authorizedkeys + OpenSSH-LPK)
      ad-group-sync.nix            # generic AD-group → local-group bridge (krg.adGroupSync) — re-derives a fixed-GID local group's members from one+ AD groups via a oneshot+10-min timer. Consumed by nvidia.nix (cudaAccessGroups → GPU device group) and docker.nix (accessGroups → docker daemon group)
      security/{fail2ban,firewall,oec-qualys-trellix}.nix   # firewall is the single switch
      services/{compose-stack,node-exporter,ipmi-exporter}.nix
      hardware/{nvidia,fpga}.nix   desktop/xrdp.nix
    profiles/
      base.nix                     # every host: SSH hardening, auto-upgrade, OEC + fail2ban + node-exporter + in-guest firewall; isVM enables qemu-guest-agent
      server.nix                   # krg-prod / e4e-prod role (docker, compose, ipmi exporter)
      compute.nix                  # waiter role (physical; NVIDIA/FPGA/XRDP/ZFS)
      directory.nix                # krg-ldap role: Samba AD DC (realm KRG.LOCAL)
    hosts/{krg-prod,e4e-prod,waiter,krg-ldap}/{default,hardware-configuration}.nix
    users/admin.nix                # local break-glass admin (krg-admin/e4e-admin); home /var/lib/<account> (OFF /home, so an NFS /home mount can't shadow it); keys from keys/admins.json; human users come from Samba AD
    docker-compose/                # compose stacks mounted by the flake
      krg-prod/                    # the lab-wide services stack (Traefik, Authentik, Grafana, …) wired into nix/hosts/krg-prod/default.nix
      dcgm-exporter/               # standalone NVIDIA DCGM exporter, wired by modules/hardware/nvidia.nix (krg.nvidia.dcgmExporter) — there is no per-host waiter/ dir, just this
  ansible/                         # Proxmox hypervisor hosts (Debian/PVE)
    ansible.cfg  requirements.yml
    inventory/
      hosts.yml                    # the Proxmox hosts (group: proxmox) — currently one host, "fabricant"
      group_vars/{all,proxmox}.yml # next to the inventory (so ansible-playbook loads it): all.yml = generic baseline (keys/trusted nets via the shared files); proxmox.yml = PVE-specific
      host_vars/fabricant.yml      # fabricant-ONLY vars (NFS shares, ZFS limits, host.fw rules)
    playbooks/site.yml             # all hosts → base; proxmox group → proxmox_firewall; fabricant → zfs_limits + nfs_server
    roles/
      base/                        # THE baseline: OS basics (timezone, packages incl tmux, unattended upgrades, sysctl) + composes the security/monitoring roles below (import_role, ordered: krg_admin → ssh_hardening → fail2ban → monitoring → oec)
      krg_admin/                   # key-only sudo krg-admin (mirrors nix/users/admin.nix)
      ssh_hardening/               # disable password auth, root key-only (the breach fix)
      fail2ban/                    # sshd brute-force jail
      monitoring/                  # node + ipmi exporters (systemd) — on every host via base
      oec_qualys_trellix/          # campus-mandated Qualys + Trellix (set oec_installer) — via base
      proxmox_firewall/            # PVE cluster.fw + per-guest <vmid>.fw + per-node host.fw (host rules eval before cluster rules; proxmox group, separate play)
      zfs_limits/                  # quota/reservation on EXISTING ZFS datasets — caps VM storage so user data wins (fabricant ONLY play)
      nfs_server/                  # NFSv4 exports on ZFS datasets under <pool>/nfs (fabricant ONLY play; NFS tcp/2049 opened via fabricant host.fw); ALSO schedules zfs-auto-snapshot (systemd timers) for the opted-in shares — Proxmox has no NixOS services.zfs.autoSnapshot, so retention here MIRRORS nix krg.zfs.autoSnapshot, scoped opt-in via --default-exclude
  terraform/                       # OpenTofu layer — one root module (own state+creds) per target
    README.md  .gitignore          # layer conventions; .gitignore is top-level (covers all targets: *.tfstate*, *.tfvars)
    e4e-nas/                       # Synology DSM (synology-community/synology): versions/providers/variables.tf + containers/packages/scheduler.tf (templates, commented)
    authentik/                     # PLANNED (goauthentik/authentik): Authentik SSO objects — apps/providers/flows/groups (README stub)
    vault/                         # PLANNED (hashicorp/vault): auth methods/policies/secret engines — structure not values (README stub)
  spec/e4e-nas/                     # declarative DSM source of truth (shares/groups/smb-globals/nfs-exports/acls/users/garage) — consumed by ansible synology_* roles; seeded from docs/e4e-nas-dsm.md
  docs/
    creating-a-user.md             # AD user-creation runbook
    e4e-nas-dsm.md                 # DSM runbook: the NAS settings with no API (AD join, shares/ACLs, firewall, SSH, snapshots, updates) — → break-glass once spec/ seeded
    krg-prod-iac.md                # krg-prod IaC architecture + NAS standup plan (how the spec maps onto this repo)
    adr/                           # Architecture Decision Records — 0001 IaC-source-of-truth, 0002 Garage, 0003 Garage-on-NAS, 0004 VM-IO-budget, 0005 repo-integration/OpenTofu/krg-deploy
```

> **Naming note:** `fabricant` now refers only to the Proxmox **host** (hypervisor,
> in the ansible inventory). The old nix `fabricant` services config was split into
> `krg-prod` (lab-wide tools) and `e4e-prod` (E4E project services).

## Architecture: Key Patterns

### 0. Firewall ownership (defense-in-depth, split by layer)

Each layer owns the firewall concern it's best at, so they don't drift:
- **In-guest NixOS firewall (`krg.firewall`) — on EVERY host, VMs included.** It
  owns *which ports* a service exposes (e.g. `samba-ad.nix` declares the AD port
  set) and gives **fail2ban** a backend (the countermeasure to the dictionary
  attack that drove this rebuild). `profiles/base.nix` sets it `mkDefault true`.
- **Proxmox host firewall (`ansible/`) — additive perimeter.** Owns *which
  sources* may reach a VM, plus containment. Services → `ucsd`/`sealab`; compute
  (waiter) → public SSH (protected by key-only + fail2ban). Does **not** replace
  the in-guest layer.

### 0b. Shared data across layers

Values needed by both nix and ansible live in one file each, under `nix/` (the
flake can only read its own subtree); ansible reads them across the repo:
- `nix/keys/admins.json` — admin SSH public keys (not secret).
- `nix/networks/trusted.json` — trusted nets / Proxmox IPSets + monitoring host.
Edit these, not the per-layer copies.

### 1. NixOS modules vs Docker Compose

Services that were **native systemd** in Ansible (node_exporter, ipmi_exporter) use native NixOS `services.prometheus.exporters.*` modules. Everything else stays as **Docker Compose** stacks managed by `krg.composeStacks`.

The `compose-stack` module runs each stack as a `systemd` oneshot service with `docker compose --project-directory <workingDir> -f <nix-store-path> up -d`. The `--project-directory` flag makes Docker Compose resolve relative volume paths (like `./.secrets/foo.txt`) against the **working directory** (e.g. `/var/lib/krg/krg-prod/`), not the Nix store. The compose files stay read-only in the store; runtime data (databases, secrets, config) lives in the working directory.

### 2. Compose file `include:` and the directory reference pattern

`compose.yml` uses Docker Compose's `include:` directive to pull in sub-stacks. For this to work when the compose files are in the Nix store, the entire `nix/docker-compose/krg-prod/` **directory** must be in the same store path. Always reference the directory, not individual files:

```nix
# In nix/hosts/krg-prod/default.nix — correct pattern
let composeDir = ../../docker-compose/krg-prod; in
{
  krg.composeStacks.krg-prod.composeFiles = [ "${composeDir}/compose.yml" ];
}
# The whole docker-compose/krg-prod/ directory is copied to the store,
# so include: can find compose.authentik.yml etc. alongside compose.yml.
```

### 3. Adding a new machine (NixOS)

1. Run `nixos-generate-config --show-hardware-config` on the target; save as `nix/hosts/<name>/hardware-configuration.nix`
2. Create `nix/hosts/<name>/default.nix` importing the appropriate profile plus any `krg.composeStacks`
3. Add the host to `nix/flake.nix` under `nixosConfigurations`
4. `git add` the new files (a flake only sees git-tracked files), `nix flake check ./nix`, then deploy with `nixos-rebuild switch --flake ./nix#<name> --target-host ...`

## Secrets (Pre-Vault)

Secrets are **not** managed by Nix yet (future: HashiCorp Vault — Bitwarden is no longer used). Before starting each compose stack, manually create the required files in the working directory. Each host's `default.nix` lists required secrets in a comment.

**krg-prod** secrets in `/var/lib/krg/krg-prod/.secrets/`:
- `authentik_postgres_admin_password.txt`
- `authentik_admin_password.env` (`AUTHENTIK_SECRET_KEY=...` and `AUTHENTIK_POSTGRESQL__PASSWORD=...`)
- `authentik_traefik_token.env`
- `gf_admin_password.txt`
- `label_studio_admin_password_pg.env`
- `postgres_admin_password.txt`
- `outline_secrets.env`
- `mlflow.env` (`POSTGRES_PASSWORD`, `OIDC_*` variables)

The `.secrets/` directories are in `.gitignore`.

## Runtime Config Directories

The grafana/prometheus/loki compose services mount config from the working directory. Before starting the krg-prod stack, populate:
- `/var/lib/krg/krg-prod/grafana/` — Grafana config
- `/var/lib/krg/krg-prod/loki/loki-config.yaml` — Loki config
- `/var/lib/krg/krg-prod/loki/promtail-config.yaml` — Promtail config (update to NixOS journal or `/var/log`)
- `/var/lib/krg/krg-prod/prometheus/prometheus.yml` — Prometheus scrape config (still references `fabricant.ucsd.edu` targets — update to the new host DNS)
- `/var/lib/krg/krg-prod/blackbox-exporter/blackbox.yml` — copy from `nix/docker-compose/krg-prod/blackbox-exporter/blackbox.yml`

## Pending Items

- [ ] **DNS/URL migration for krg-prod**: the compose files still serve `*.fabricant.ucsd.edu` (Traefik routes, OIDC URIs) and scrape `fabricant.ucsd.edu` — decide whether to keep or move to a new scheme, then update the compose files + Prometheus targets accordingly.
- [~] SSSD AD client integration — **built into the baseline on both layers** so every host joins Samba AD (`KRG.LOCAL`) and humans log in with their AD accounts (only `nix/users/admin.nix` break-glass stays local). nix: `krg.adClient` (`nix/modules/sssd-ad-client.nix`), enabled in `profiles/base.nix` (the DC sets `isDomainController`). ansible: `roles/ad_client`, composed into the `base` role. Both: algorithmic ID mapping (auto uid/gid), key-only SSH with keys served from AD (`sss_ssh_authorizedkeys` + the OpenSSH-LPK `sshPublicKey` schema extension), access restricted to `Domain Admins` by default (widen per host). User-creation runbook: `docs/creating-a-user.md`. **Status** (per `docs/joining-a-host-to-the-domain.md`): krg-ldap provisioned + keytab exported; **waiter joined 2026-05-21**; fabricant + krg-prod + e4e-prod still pending domain join + on-box validation. Compute hosts widen via `krg.adClient.allowedGroups` (waiter: `Domain Admins` + `Waiter`). Do NOT import the old domain's password hashes — they're compromised; users get new passwords.
- [x] Real SSH public keys added to `nix/keys/admins.json` (chris, dzuberi, dzube, shperry for krg-admin; chris, shperry, treez for e4e-admin — all ed25519). Shared by both layers.
- [ ] Replace placeholder `hardware-configuration.nix` files for the unbuilt hosts (waiter's is real; krg-prod/e4e-prod/krg-ldap pending first deploy).
- [~] Qualys Cloud Agent + Trellix HX (xagt): nix module `nix/modules/security/oec-qualys-trellix.nix` (enabled for all hosts via `base.nix`); Ansible counterpart `oec_qualys_trellix` role built and composed into the `base` role (runs on every host; set `oec_installer` to the vendor archive, else it no-ops). Installer archive at `/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz` (NOT in git — live credentials). **Both sides still need on-box validation.**
- [~] Samba AD domain controller (`krg-ldap`, VMID 100 on the `fabricant` Proxmox host): `nix/modules/samba-ad.nix`, enabled via `nix/profiles/directory.nix` (new forest `KRG.LOCAL`, `SAMBA_INTERNAL` DNS). **Provisioned** on-box (`samba-tool domain provision`) and **keytab exported** to members (`samba-tool domain exportkeytab` — see `docs/joining-a-host-to-the-domain.md`). Still pending: populate AD users/groups (no real principals yet — see [[krg-local-ad-principals-pending]]), and lab-group widening per host.
- [~] Proxmox host hardening (`ansible/`): the `base` role IS the baseline — OS basics + `krg_admin` + `ssh_hardening` + `fail2ban` + `monitoring` (node + ipmi exporters) + `oec_qualys_trellix`, composed in order via `import_role` (secure + up to date + monitored + enrolled by default). `proxmox_firewall` (`cluster.fw` templated from `trusted.json` + per-guest `<vmid>.fw`, e.g. `100.fw` for krg-ldap) is a separate `proxmox`-group play — **it fixes the live cluster.fw finding** (SSH + exporters currently open to `+dc/public`). All roles built; **inputs filled**: `inventory/hosts.yml` has `fabricant` (running in `ansible_connection: local` mode on the PVE host itself), real admin keys are in `nix/keys/admins.json`, and `nix/networks/trusted.json` has real CIDRs/IPSets. **Pending:** point `oec_installer` at the vendor archive on fabricant + on-box validation of the full play.
- [ ] nix in-guest service-SSH restriction (read `ucsd`/`sealab` from `trusted.json` so service hosts restrict 22 in-guest too).
- [~] **Docker published-port firewall bypass.** Docker DNATs published ports through the FORWARD path, bypassing `krg.firewall`'s nftables INPUT rules — so the in-guest firewall can't govern container ports. **Done:** `krg.docker.defaultPublishAddress` (`nix/modules/docker.nix`, default `127.0.0.1`) binds unspecified publishes to loopback fleet-wide, so DBs/exporters (authentik/label-studio Postgres, loki, blackbox) stay off the external interface; intentionally-public ports opt in with `0.0.0.0:` (Traefik 80/443, dcgm 9400). It also tightens ad-hoc `docker run -p X:Y` on compute boxes to loopback (use `-p 0.0.0.0:…` or an SSH tunnel to expose). **Still open:** ports bound to `0.0.0.0` for *remote* scraping — notably **dcgm 9400 on physical/public waiter** — remain world-reachable; `krg.firewall.monitoringPorts = [9400]` (nvidia.nix) does NOT enforce against the Docker-forwarded port. Needs a `DOCKER-USER`/nftables FORWARD rule restricting 9400 to `monitoringSourceIp` — must match on the external ingress interface (`eno1` on waiter) so container-to-container traffic isn't dropped; wants on-box validation.
- [ ] TOTP 2FA on the PVE realm; PVE web-UI fail2ban jail (needs `filter.d/proxmox.conf`); PVE patching + persistence hunting (post-breach).
- [ ] Add Vault for secrets management (replacing manual `.secrets/` population).
- [x] **waiter NFS `/home` + impermanence — DONE + validated on-box (2026-05-21).** `/home` is served from fabricant (`rpool/nfs/home`, ansible `nfs_server`) and mounted on waiter via `krg.nfsHome` (`modules/nfs-home.nix`), moving user homes OFF the rolled-back root. `krg.impermanence.enable = true` (PR #12), validated across two reboots (rollback fires each boot; `/persist` preserves keytab/host-keys/machine-id + the break-glass admin home `/var/lib/<account>`; `/home`, AD, 0 failed units). Two boot bugs were fixed to get here: the `/home` mount is now a plain `nofail` mount (NOT `x-systemd.automount`, which wedged early boot — PR #9), and `modules/impermanence.nix` reseeds `/usr/bin/env` in initrd to survive systemd 258's empty-`/usr` PID1 freeze (PR #11). Recovery if a blanked root ever freezes: GRUB `boot.debug1mounts` → recreate `/usr/bin/env`. (Docker has its own `nvmepool/docker` dataset, durable regardless.)
- [x] **Gate AD logins on the NFS `/home` mount (impermanence data-loss window) — DONE (PR #13).** The window: with impermanence + the `nofail` `/home` mount, if fabricant (NFS) is down at boot `/home` is left unmounted; an SSSD-cached AD login then triggers `pam_mkhomedir` to create an ephemeral home on the rolled-back root, wiped on the next reboot. Closed by `krg.nfsHome.requireMountForLogin` (default **on**) in `nix/modules/nfs-home.nix`: a `pam_exec` **account** check (added to sshd + login) denies any user whose home is **under the NFS mountpoint** when that mount is not active, relaying the reason to the user; break-glass `krg-admin` (home `/var/lib/<account>`, off `/home`) matches nothing and logs in normally, so the box stays recoverable while NFS is down. Enabled on waiter (it doesn't override the default). (The newer `krg.scratch` per-user dirs apply the same fail-closed guard for `/scratch`: created only while the mount is active.)
- [ ] **Second AD DC (remove the krg-ldap SPOF).** Today every host's login depends on the single `krg-ldap` VM on the `fabricant` hypervisor. Plan: stand up a second Samba AD DC on **another Proxmox host** before go-live. When it lands, let members fail over — either drop the pinned `krg.adClient.server`/`serverIp` so SSSD uses DNS SRV autodiscovery, or extend the module to list both DCs (and pin both in `/etc/hosts`). Until then, the SSSD offline cache (`cache_credentials=true`) + local break-glass `krg-admin` are the only continuity if krg-ldap is down.
- [~] **e4e-nas (Synology DSM) under IaC management — PR #8 (built, pending bring-up).** Three-layer surface: **terraform/e4e-nas/** (community `synology` provider for Container Manager / packages / scheduler / VMs — scaffolded, resources commented pending provider-attr verification + DSM API creds); **spec/e4e-nas/*.yml** (20 declarative spec files — shares, ACLs, SMB, NFS, users, groups, DSM web/system, security, notifications, app portal, SSH, AD, dsm-updates, security-advisor, external-access, quotas, snapshots, hyper-backup); **ansible/synology/** (self-contained subtree — 20 roles + composer + own ansible.cfg/inventory/group_vars; `rm -rf ansible/synology/` is the decommission). Roles wrap synowebapi/synouser/synoshare/synoacltool via `script:`+`raw` (DSM py3.8 is below ansible's module floor). **synology_base** composer enforces a load-bearing order: dsm_system → users → ssh → security → external_access → dsm_web → services → notifications → security_advisor → dsm_updates → ad (AD last, anti-lockout). Hardening: e4e-admin break-glass + key-only SSH + Telnet/SFTP off, QuickConnect/UPnP off, autoblock 3/24h/permanent, SMB3-min/NTLMv1-off, FTP/AFP off, SNMPv3 (krg-monitor), TLS Modern profile, Security Advisor weekly, hotfix-security DSM auto-updates. Per-share Btrfs snapshot retention; Hyper Backup declarative (jobs:[] today — destination decision open). **AD join** to KRG.LOCAL (winbind, idmap reconciled to match SSSD's algorithmic range so the fabricant-prod NFS export works). ADR 0006 (no Qualys/Trellix on DSM — DSM-native Security Advisor replaces it; compliance carve-out filing owed to UCSD ITS). 160/160 tests green; reviewed by Copilot + a full code review (4577021512), all H/M/Low items addressed. **Bring-up gates** (docs/e4e-nas-dsm.md): pre-flight live captures (Hyper Backup jobs + AppPortal lists + network — declarative sync deletes anything not in spec), .dss config backup off-box, rig validation to flip OUT_KEYS field-name mismatches, Phase 1 (Mode 2 reset → wizard → re-enter static IP → e4e-admin + NOPASSWD sudo) → Phase 3 `--check --diff` then incremental apply. **Follow-ups** (own PRs): #75 `secret/e4e-nas/users/*` AppRole in OpenBao + `synouser --setpw` task, #77 NAS in Grafana (SNMP exporter + dashboard), #85 synology-apply systemd timer on krg-deploy.
- [x] **`/scratch` — GREENFIELD ZFS-native rebuild — DEPLOYED on waiter.** Supersedes the autotier design (PR #14): autotier (FUSE) **crashed (SIGABRT) under concurrent training reads** — it wrote a RocksDB record per file open/close — and is unmaintained; removed entirely. Design (`docs/scratch-greenfield.md`, `nix/modules/scratch.nix`, `nix/hosts/waiter/disko-config.nix`): **one `scratchpool`** = 2× HDD **striped** data (~29 TiB, no redundancy, regenerable) + NVMe **special** vdev (metadata-only, striped) + NVMe **L2ARC** (striped). `nvmepool` (RAIDZ1, 4× NVMe `os` partitions) keeps OS/`/tools`/`/local`. `/scratch/krg` is a **plain ZFS mount** (no FUSE): ZFS serves hot reads from ARC→L2ARC→HDD in-kernel. **Lab isolation:** real `3770` (setgid+sticky) `Kastner Research Group` (no FUSE, no o+x hack; sticky stops members deleting each other's per-user dirs). **Snapshots OFF** on scratch-krg (regenerable + they'd pin blocks the overflow frees); cold copies on fabricant NFS stay snapshotted. **`relatime`** so the mover can pick least-recently-accessed files. **Per-user dirs** via the same `pam_exec` hook, guarded on the mount. **Overflow (capacity backstop + TTL GC, OUT of the read path):** daily `scratch-overflow` timer (Python, `modules/scratch/scratch-overflow.py`) demotes files to fabricant NFS (`/srv/scratch-cold/krg`) for two reasons, both by last-access (relatime): a **TTL sweep** moves anything idle >`maxIdleDays` (180 = 6mo on waiter) every run regardless of fullness (GC of abandoned data; active files never evicted), and a **capacity sweep** moves the coldest files when `scratchpool` >85% (down to 75%, floored at minAgeDays=14). **Fail-closed** (copy→fsync→verify size+sha256→atomic symlink-swap; `RequiresMountsFor` both mounts so it won't run if NFS is down; a local file is never unlinked until its NFS copy verifies; manifest records the sweep reason); `scratch-restore` (Python) pulls a file back self-service. Tooling is **Python on purpose** (correctness-critical but researcher-maintainable, no compile, no new toolchain; round-trip unit-tested). **Concurrency knobs (waiter, 377 GiB RAM):** ARC cap 96 GiB (~25%), `earlyoom` (systemd-oomd off), `smartd` (striped pool = no redundancy → need disk-failure warning). **Post-deploy fixes:** PR #66 (`fix(scratch): re-assert /scratch lab perms after tmpfiles-resetup`) bound the `krg-scratch-perms-<lab>` oneshot to `systemd-tmpfiles-resetup.service` after the nightly nixos-upgrade left `/scratch/krg` as `drwxr-xr-x root root` in the wild. ansible `nfs_server` exports `rpool/nfs/scratch-krg` (`no_root_squash`) as the cold overflow target; the old `bulk` cleanup (`zfs destroy rpool/nfs/bulk`) still stands. **e4e later:** add a `projects.e4e` (scratchpool/scratch-e4e is reserved scaffolding) with e4e-nas as its overflow target. **Follow-up (accepted, documented in docs/scratch-greenfield.md):** a residual restore TOCTOU — a symlinked parent-dir component swapped after `scratch-restore`'s containment checks could redirect the publish; only bites an admin running restore as ROOT on a crafted `/scratch` path (normal restores run as the owner; bytes are the user's own). Full fix = per-component `openat`/`dir_fd` traversal; deferred as disproportionate vs the tool's simple/maintainable goal (Copilot review round 15, left as a tracked follow-up not a blocker).
- [x] **node-local `/local/<user>` fast cache — DEPLOYED on waiter.** The counterpart to scratch: `krg.localCache` (`nix/modules/local-cache.nix`) moves regenerable, hot, NODE-local per-user state OFF the NFS `/home` onto a plain durable NVMe dataset (`nvmepool/local` → `/local`, legacy mount, off the `@blank` rollback — so NO `/persist` bind needed, like `/var/lib/docker`). Two kinds move: (1) **IDE remote servers** `~/.vscode-server` + `~/.cursor-server` via a login-time **symlink** into `/local/<user>/`; (2) the **cache class** — `XDG_CACHE_HOME`, `HF_HOME`, `TORCH_HOME`, `CONDA_PKGS_DIRS`, `npm_config_cache` — via `environment.shellInit` exports computed with `id -un` (only when `/local/<user>` exists). Only **caches** move; conda **envs**/real data stay in `/home`. **Why not `/home`:** small-file/watch-heavy IDE + cache I/O is exactly NFS's worst case (inotify doesn't cross NFS → polling watchers), and it's regenerable so it doesn't deserve durable network home space. **Why not `/scratch`:** scratch DEMOTES cold files to NFS when the pool fills (opposite of what you want for a dev cache) — `/local` is the deliberately boring pure-NVMe path that never overflows. **Per-user dir** auto-created by a `pam_exec` session hook (order 13500, `optional` so it never blocks login), guarded on `/local` being mounted; the **symlink is never created over an existing real path** (so an existing `~/.vscode-server` on NFS is untouched). On **waiter** (`krg.localCache.enable + perUser.enable`). **MIGRATION:** existing users opt in once with `rm -rf ~/.vscode-server` (then next login symlinks it). **Post-deploy fix:** PR #68 (`fix(local-cache): self-heal dangling IDE-server symlinks`) made the login hook recover when `/local` is reprovisioned (e.g. disko repartition) and the home-side symlink is left dangling — observed in the wild as `mkdir: cannot create directory '~/.vscode-server': File exists` on Remote-SSH connect.
