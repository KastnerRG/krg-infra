# krg-infra — Proxmox host management (Ansible)

The **hypervisor** half of the `krg-infra` monorepo. The flake under `nix/`
configures the NixOS machines; this Ansible tree configures the **Proxmox/Debian
hosts** they run on. Goal: **machines secure and up to date by default.**

## Why this exists

A Proxmox host's root SSH was **dictionary-attacked** — that breach drove this
rebuild. The NixOS guests were already hardened, but the hypervisors had **no
config management** and were left at insecure SSH defaults. This tree closes
that gap, reusing the prior `KastnerRG/fabricant-host` setup but refactored into
generic, push-based roles applied to *every* host (it was only ever applied to
one). No Bitwarden — real secrets will live in HashiCorp Vault later.

## Layout

```
ansible/
  ansible.cfg
  requirements.yml            # collections: ansible.posix, community.general
  inventory/
    hosts.yml                 # the Proxmox hosts (group: proxmox) — fill in
    group_vars/               # MUST live next to the inventory so ansible-playbook loads it
      all.yml                 # generic baseline vars (admin keys, timezone, crowdsec, trusted nets)
      proxmox.yml             # PVE-specific vars (firewall IPSets / VM map — with proxmox_firewall)
    host_vars/
      fabricant.yml           # fabricant-ONLY vars (NFS shares, ZFS limits, host.fw rules)
  playbooks/site.yml          # baseline (all) + proxmox firewall (proxmox) + storage (fabricant)
  roles/
    base/                     # THE baseline — OS basics (timezone, packages incl tmux,
                              #   unattended upgrades, sysctl) + composes the security +
                              #   monitoring stack below (import_role, in order)
    krg_admin/                # break-glass krg-admin (sudo, key-only) — mirrors nix/users/admin.nix
    ssh_hardening/            # disable password auth, root key-only (the breach fix)
    crowdsec/                 # community CTI + local scenarios — the fleet brute-force/ban layer
    monitoring/               # node + ipmi exporters (systemd) — on every host
    oec_qualys_trellix/       # campus-mandated Qualys + Trellix (set oec_installer)
    ad_client/                # SSSD AD client — every host joins KRG.LOCAL (key-only SSH, keys from AD)
    proxmox_firewall/         # PVE cluster.fw + per-guest <vmid>.fw + per-node host.fw (proxmox group)
    zfs_limits/               # quota/reservation on existing ZFS datasets (fabricant ONLY play)
    nfs_server/               # NFSv4 exports on ZFS datasets (fabricant ONLY play)
    ipmi_lan/                 # enforce the BMC's static LAN IP in-band via ipmitool (fabricant ONLY play; nix counterpart: krg.ipmiLan)
```

Every host gets the baseline by applying a single role, `base`, which composes
`krg_admin`, `ssh_hardening`, `crowdsec`,
`monitoring`, `oec_qualys_trellix`, and `ad_client` in a deliberate order (see
`roles/base/tasks/main.yml`). `proxmox_firewall` is the
one perimeter concern that stays a separate, `proxmox`-group-only play in
`site.yml` (it's a hypervisor concern, not an all-hosts default).

`zfs_limits` + `nfs_server` are a **`fabricant`-only** play (not the `proxmox`
group). `nfs_server` carves a `<pool>/nfs` ZFS dataset and exports `home` +
`scratch-krg` (waiter's `/scratch` cold-overflow tier) over **NFSv4** (single tcp/2049); `zfs_limits` caps the *other* datasets (e.g. the
VM disks) so user/NFS data wins pool contention. Pool, shares, clients, and quotas
live in `inventory/host_vars/fabricant.yml`. The NFS port is opened in fabricant's
**per-node `host.fw`** (host-scoped, via `proxmox_host_fw_rules`) — NOT cluster.fw,
so it stays fabricant-only as more nodes join. PVE compiles host.fw rules into the
host chain *before* the cluster.fw rules, so cluster.fw's terminal `IN DROP` doesn't
shadow them. (`policy_in`/`log_level_in` are host/VM-level options, invalid in
datacenter `[OPTIONS]` — PVE warns and ignores them — so the deny stays a rule.)

Admin SSH keys are **shared** with the NixOS layer — edit `nix/keys/admins.json`
(read by both); do not duplicate keys here.

> **Note:** `ansible/synology/` is a separate, self-contained subtree (its own
> `ansible.cfg`/inventory/roles) that manages the Synology e4e-nas appliance — it
> is **not** part of the Proxmox-host play here. See
> [`ansible/synology/README.md`](synology/README.md).

## Before you run

1. `ansible-galaxy collection install -r requirements.yml`
2. Add the host(s) to `inventory/hosts.yml` (currently: one host, `fabricant`).
3. Set the real ops key(s) in `nix/keys/admins.json` and the trusted nets in
   `nix/networks/trusted.json` (read into `krg_trusted` by `inventory/group_vars/all.yml`).

> **Anti-lockout:** `ssh_hardening` authorizes your key *before* turning password
> auth off, asserts a key is set, and validates `sshd -t` before restarting (a
> bad config aborts before the restart). Still — keep a Proxmox **console**
> session open the first run and confirm a *new* key-based SSH session works
> before closing your current one.

## Run

```bash
ansible-playbook playbooks/site.yml --check     # dry run
ansible-playbook playbooks/site.yml
```

## Not done yet (next)

The roles are all built and wired in. **Inputs are now filled** — `inventory/hosts.yml`
has `fabricant` (running in `ansible_connection: local` mode on the PVE host itself),
real ed25519 keys are in `nix/keys/admins.json`, and `nix/networks/trusted.json` has
real CIDRs/IPSets (read into `krg_trusted`). What remains is on-box validation, not
new code:

- **`oec_installer`**: point at the local vendor archive on fabricant (no archive →
  the OEC step no-ops rather than failing).
- **On-box validation**: confirm `monitoring` (node + ipmi exporters) and
  `oec_qualys_trellix` (Qualys + Trellix enroll/run) on a real PVE host.
- `proxmox_firewall`: `cluster.fw` (IPSets `public`/`sealab`/`ucsd`) + per-guest
  `<vmid>.fw` (krg-ldap = 100). **Tightens SSH + the exporters off `+dc/public`**
  — services → `ucsd`/`sealab`, compute → public SSH, exporters → monitoring host.
- `nfs_server` + `zfs_limits` (fabricant): pool (`rpool`), 20T reservation on
  `rpool/nfs`, 2T cap on `rpool/data`, and the NFS tcp/2049 host.fw rule are all set
  in `host_vars/fabricant.yml`. **Pending on-box validation:** run the play, confirm
  the datasets/quotas, that `pve-firewall compile` shows the 2049 ACCEPT before the
  default drop, and that a client can mount `fabricant:/srv/nfs/home`. Widen the
  export + host.fw client lists (keep them in sync) as more hosts mount.
- TOTP 2FA on the PVE realm; PVE web-UI brute-force jail; PVE patching + persistence
  hunting (post-breach).
