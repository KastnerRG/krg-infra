# Onboarding `kastner-ml` into the fleet (NixOS + ZFS)

Bringing **kastner-ml** — a smaller GPU compute box currently running Ubuntu —
into the fleet as a new NixOS machine. This is the **as-planned** record: the
hardware inventory, the ZFS disk design and the decisions behind it, the host
integration, and the remote bring-up runbook. Nothing here is applied yet; the
disk wipe is destructive and gated on the checklist at the end.

> **Related:** [waiter-topology.md](waiter-topology.md) (the closest sibling —
> the other physical compute box) · [scratch-greenfield.md](scratch-greenfield.md)
> (the `/scratch` design this mirrors) ·
> [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) (the AD join
> step) · [fleet-inventory.md](fleet-inventory.md). Sources to be added:
> `nix/hosts/kastner-ml/{disko-config,hardware-configuration,default}.nix`,
> `nix/flake.nix`.

---

## What kastner-ml is

An **E4E** single-GPU compute node — E4E-owned *and* E4E-used (the **KRG lab
generally does not use it**), so it takes the **`e4e-admin`** break-glass account
like e4e-prod, not `krg-admin`. A CSE237D course has accounts here, but it's not a
KRG-lab resource. Sibling to **waiter** but smaller and with a fundamentally
different disk topology (3 heterogeneous disks, **no redundancy possible** — one
of each kind).

| | kastner-ml | waiter (contrast) |
|---|---|---|
| CPU | Intel Xeon E5-1650 v4, 6c/12t @ 3.6 GHz | larger |
| RAM | 125 GiB | 377 GiB |
| GPU | 1× **NVIDIA RTX A6000** (48 GB) | multi-GPU |
| Boot | UEFI, **Secure Boot disabled** (Setup Mode) | UEFI |
| Primary NIC | `eno1` → **132.239.17.123/24**, gw 132.239.17.1 (public UCSD) | public 137.110.x |
| Other NIC | `enp11s0` — DOWN | — |
| Current OS | Ubuntu 24.04.4 LTS, root on **btrfs-over-bcache** (3.1 TB used) | NixOS |

Because the primary interface holds a **public UCSD address**, kastner-ml takes
the same perimeter posture as waiter: key-only SSH + CrowdSec, in-guest firewall,
and care with any Docker-published ports (see the DOCKER-USER note in
[waiter-topology.md](waiter-topology.md)).

### Disks (by-id — the names the disko config MUST use)

| Role | Device (`/dev/disk/by-id/…`) | Size | Notes |
|---|---|---|---|
| HDD (bulk) | `ata-WDC_WD80EFZX-68UW8N0_R6G808WY` | 8 TB (7.28 TiB) | WD Red, 4Kn |
| SATA SSD | `ata-CT2000MX500SSD1_1817E13973A1` | 2 TB | Crucial MX500 |
| NVMe | `nvme-INTEL_SSDPEK1W120GA_PHBT8070009L128R` | 118 GB | **Intel Optane 800P** — low-latency, high-endurance |

> **GOTCHA — use the `by-id` names above, never `/dev/sda`/`/dev/nvme0n1`.**
> Kernel names reshuffle across enumeration and ZFS would fail to import. (Same
> rule as [`waiter/disko-config.nix`](../nix/hosts/waiter/disko-config.nix).)

There is also a CIFS mount on the live box, `/mnt/backup` →
`//e4e-nas.ucsd.edu/2026_kastner_ml_dump` (45 TB used) — this box already backs
up to the NAS. **Confirm that dump is current before wiping** (see the bring-up
checklist).

---

## The core design problem (vs. waiter)

Waiter's layout — a RAIDZ1 `nvmepool` plus a striped `scratchpool` — **does not
map** here. There is exactly one of each disk type, so **no vdev can be
redundant**. The design therefore keeps waiter's *role split* (OS pool / scratch
pool, impermanence-ready root, `/local` off the NFS home, `/scratch` = HDD bytes
accelerated by NVMe metadata + L2ARC) but adapts it to three single disks.

### Device-role assignment (the load-bearing decision)

- **Optane 800P → scratch accelerator, NOT the OS.** It is the fastest,
  highest-endurance device but only 118 GB — too small for the nix store + CUDA
  Docker images. Its best use is the `special` (metadata-only) + `cache` (L2ARC)
  vdevs for the 8 TB HDD scratch pool, exactly waiter's pattern. Metadata on
  Optane keeps `find`/listings over 7 TB NVMe-fast; L2ARC serves hot training
  reads from NVMe.
- **MX500 2 TB SSD → OS pool (`rpool`):** root, nix, persist, tools, docker, and
  `/local`. Plenty of room; puts the dev/cache class on local SSD instead of NFS.
- **WD 8 TB HDD → scratch bulk data** (`/scratch/krg`).

---

## Finalized ZFS disk layout

```
MX500 2TB   ESP   2G    vfat  → /boot   (GRUB, single boot disk)
  (rpool)   zfs ~1862G → rpool          [single-disk, no redundancy]
                           root     legacy + @blank rollback (impermanence)
                           nix      legacy, no-snapshot
                           persist  legacy, snapshots ON  (keytab/host-keys/machine-id)
                           tools    legacy
                           docker   legacy → /var/lib/docker, no-snapshot
                           local    legacy, quota 500G → /local

Optane 118G special 48G → scratchpool special  (metadata-only vdev)
            cache   56G → scratchpool cache     (L2ARC)
            ~6G slack (SSD overprovisioning / endurance)

WD 8TB      zfs 100% → scratchpool data         [single vdev]
                         scratch-krg  legacy, recordsize=1M, relatime=on,
                                      snapshots off → /scratch/krg (krg.scratch)
```

- Both pools `ashift=12` (HDD 4Kn, SSD 4K physical; Optane tolerates it).
- ESP is 2G (not 1G) because GRUB `copyKernels` stores ZFS initrds on the vfat
  ESP and all `configurationLimit` generations must fit — same reasoning as
  waiter. Single boot disk here, so **no `mirroredBoots`** (waiter mirrors across
  4 NVMe; kastner-ml has one OS disk).
- The root dataset captures an empty **`@blank`** snapshot at install for the
  impermanence rollback; `modules/impermanence.nix` reseeds `/usr/bin/env` in
  initrd so an empty root still boots under systemd 258 (the bug fixed for
  waiter — see [scratch-greenfield.md](scratch-greenfield.md) and the Pending
  Items in [CLAUDE.md](../CLAUDE.md)).

### Redundancy: accepted as none

| Pool | Redundancy | Why it's acceptable |
|---|---|---|
| `rpool` | none (single SSD) | OS is flake-reproducible; `/persist` (keytab/host-keys/machine-id) is re-derivable — re-join AD, regenerate host keys. Optionally snapshot-send `/persist` to the NAS as a nicety. |
| `scratchpool` | none (single HDD data, single Optane special) | Losing the Optane loses the pool. **Accepted under the same logic as waiter:** scratch is regenerable, cold files overflow to NFS (snapshotted there), and `smartd` (compute profile) warns early. Metadata spills gracefully to the HDD if `special` ever exceeds 48 G, so the sizing is not load-bearing. |

This was a deliberate decision — the alternative (mirroring the `special` vdev
onto a slice of the 2 TB SSD to survive Optane death) was weighed and **declined**
to match fleet philosophy: scratch is regenerable, the data vdev would still be a
single HDD, and the simplicity is worth more than protecting only the metadata.

---

## Home and root model

kastner-ml follows the **waiter model**: NFS `/home` + impermanence (root rolls
back to `@blank` every boot; only `/persist` survives). One difference:

> **`/home` is served from `e4e-nas` (`/homes`), not from fabricant.** The
> `krg.nfsHome` module config (including `requireMountForLogin`, the fail-closed
> login gate that prevents `pam_mkhomedir` from writing an ephemeral home onto the
> rolled-back root when the NFS server is down) is otherwise identical to waiter.

**Dependency to verify before bring-up:** e4e-nas must export `/homes` over
**NFSv4 with an idmap that matches SSSD's algorithmic UID/GID range**. That
reconciliation was already done for the fabricant-prod NFS export during the AD
work (e4e-nas winbind idmap aligned to SSSD); the same must hold for the homes
export. Today the box reaches e4e-nas only over **CIFS** (`/mnt/backup`); Linux
POSIX homes with AD ownership want the **NFSv4** export instead. Scratch
cold-overflow (`krg.scratch`) would likewise target e4e-nas rather than fabricant.

This adds a **boot-time dependency on e4e-nas** for human logins; the local
break-glass `e4e-admin` (home `/var/lib/e4e-admin`, off `/home`) keeps the box
recoverable while NFS is down.

---

## Host integration (the rest of "pull into the fleet")

> **Status (2026-06-17): brought up.** The host is deployed and live on the flake:
> `nix/hosts/kastner-ml/` + the `nixosConfigurations` entry are in `main`, the
> `hardware-configuration.nix` was synced from the real box, `/home` is served from
> e4e-nas over NFS (`krg.nfsHome`, pinned v4.0 — Synology max), the Grafana compute
> dashboard and the (FPGA-decoupled) remote desktop landed, and Prometheus scrapes it
> as a real fleet host. Onboarding issue #223 is closed. **One residual:**
> `krg.adClient.allowedGroups` is still locked to `["Domain Admins"]` (fail-safe) —
> widening to the E4E project groups (`fishsense`, `aid`, `huggingface`) is gated on
> creating those AD groups (#100) and tracked in #19, so the ~61 E4E users don't have
> SSH access until that lands. See "Remaining work" below.

Contents:

1. **`nix/hosts/kastner-ml/disko-config.nix`** — the layout above.
2. **`nix/hosts/kastner-ml/hardware-configuration.nix`** — now the real config
   synced from the box (`nixos-generate-config --show-hardware-config`), no longer a
   placeholder.
3. **`nix/hosts/kastner-ml/default.nix`** — imports `profiles/compute.nix`, plus:
   - **`krg.adminAccount = "e4e-admin";`** — E4E-owned infra (overrides the
     `krg-admin` default; same as e4e-prod).
   - `krg.nvidia` for the single RTX A6000 (+ `cudaAccessGroups`, DCGM exporter).
     **CUDA toolkit: match waiter.** `krg.nvidia` already ships nixpkgs
     `cudatoolkit` + the container toolkit; with `nix-ld` that covers it. The
     Ubuntu box's apt `/usr/local/cuda` 12.6 install is deliberately **not**
     replicated — users get versioned CUDA via conda/pip wheels or containers.
   - `krg.fpga.enable = false` (no FPGA hardware) but **`krg.xrdp.enable = true`**
     — kastner-ml users want a GUI session for visualization/IDE work even though
     the box does no FPGA work. The XFCE/xrdp desktop is no longer coupled to FPGA
     (it's the compute-profile default; see `profiles/compute.nix`), so it stays
     enabled. Access is **only** through the Guacamole gateway on krg-prod — the
     inherited `krg.firewall.rdpSources` restricts 3389 to `137.110.161.106`.
   - `krg.localCache` (`/local`, **quota 500G** — chosen over waiter's 1T because
     the 2 TB SSD also holds nix store + CUDA Docker images).
   - `krg.scratch` — **group-level** scratch, one area per E4E project group
     (`fishsense`, `aid`, `huggingface`), group-owned + setgid; overflow → e4e-nas
     NFS. No KRG-lab scratch (KRG doesn't use this box). See Userspace → Scratch
     model below.
   - `krg.nfsHome` → e4e-nas `/homes`, `requireMountForLogin` on (default).
   - `krg.adClient` (KRG.LOCAL; `allowedGroups` covering the E4E project/lab groups
     — and the course group — whose members use this box).
4. **`nix/flake.nix`** — add `kastner-ml` under `nixosConfigurations`.
5. **Perimeter** — `eno1` is public; same key-only + CrowdSec posture as waiter.
   If it ever exposes a Docker-published port for remote scraping (e.g. DCGM
   9400), add the `DOCKER-USER`/nftables FORWARD restriction matching the ingress
   interface (`eno1`) — the standing waiter caveat.

> `git add` the new files before `nix flake check ./nix` — a flake only sees
> git-tracked files.

---

## Userspace — what to replicate from the Ubuntu box

kastner-ml today is provisioned by the flat ansible playbook
[UCSD-E4E/kastner-ml](https://github.com/UCSD-E4E/kastner-ml) and is **NOT
AD-joined** — it has ~61 **local** accounts (password hashes committed in
`kastner-ml_users.yaml`, per-quarter `expires`, incl. `cse237d_sp26.*` course
accounts). The port is less "translate packages" and more "re-home the identity +
sharing model onto the fleet's AD / ZFS / NFS patterns."

| Concern | Ubuntu now | Fleet target (waiter) | kastner-ml decision |
|---|---|---|---|
| Identity | ~61 local accts, hashes in git | Samba AD (`krg.adClient`) | **AD** — populate KRG.LOCAL first ([[krg-local-ad-principals-pending]]) |
| Break-glass admin | `e4eadmin` + 4 sudoers | `krg-admin` / `e4e-admin` | **`e4e-admin`** (E4E-owned) |
| GPU driver | `nvidia-driver-580-open` | `krg.nvidia.openDriver` | same |
| CUDA toolkit | full 12.6 in `/usr/local/cuda` | **none system-wide** (conda/containers + nix-ld) | **match waiter — no system toolkit** |
| Container runtime | docker-ce + nvidia runtime | `krg.docker` (AD `Docker Users`) | same |
| Desktop / RDP | XFCE + xrdp (3389) | xrdp (decoupled from FPGA) | **keep XFCE + xrdp** — GUI sessions via Guacamole; 3389 restricted to the gateway |
| Monitoring | node/dcgm/docker + dead `:9000` | native exporters + dcgm 9400 | native; **drop `:9000`** ansible-deploy-monitor |
| Firewall | ufw (exporters ← `132.239.95.67`) | CrowdSec + `monitoringPorts` | CrowdSec; reconcile scrape source w/ krg-prod |
| Sec agents | Qualys + Trellix | same (base.nix) | same |
| Auto-update / CD | unattended-upgrades + **ansible self-updater + Bitwarden** | `nixos-rebuild` / krg-deploy | **drop** the ansible/bw self-update + bw bootstrap |
| Home | local btrfs + jdupes dedupe + cifs backup | **NFS /home + impermanence** | NFS from **e4e-nas /homes**; ZFS makes jdupes moot |
| Project shares | `/share/{aid,fishsense,huggingface}` setgid | `/scratch/<lab>` per-user | **fold into group-level `/scratch/<group>`** — group-owned, setgid, group-writable (collaborative, not per-user) |
| HF cache | shared `/share/huggingface` (`hf_users`) | per-user `HF_HOME` in `/local` | **shared** — `HF_HOME` → the `huggingface` group scratch area (download once for all); overrides per-user `/local` HF cache |

**Packages** — **match waiter: a minimal system set, NOT the ansible apt pile.**
System-wide is only the fleet baseline + `cifs-utils` + `gnumake` + `zsh` +
`nix-ld` (what `compute.nix` already provides). Everything else the Ubuntu box
installs globally — `ffmpeg`, `nmap`, `nethogs`, `glances`, `graphicsmagick`,
`google-drive-ocamlfuse`, `pgloader`, `dcraw`, `ghostscript`, the `lib*-dev`
wall, `rustc`, `jdupes`, mscorefonts — is **dropped**. Users get per-project tools
via `nix-shell`/devshells, conda, or containers; **`nix-ld`** covers running
downloaded dynamically-linked binaries / conda / MATLAB (the need the Ubuntu box
met by having system libs everywhere).

### Resolved decisions

- **Ownership / admin** — E4E-owned infra → `krg.adminAccount = "e4e-admin"`.
- **CUDA toolkit** — match waiter: inherit `krg.nvidia` (open driver + nixpkgs
  `cudatoolkit` + `nvidia-container-toolkit`) + `nix-ld`. The point is **not**
  replicating the Ubuntu apt `/usr/local/cuda` 12.6 install; users get versioned
  CUDA via conda/pip wheels or containers.
- **Desktop** — **kept**: XFCE + xrdp, reached through the Guacamole gateway (the
  desktop is decoupled from FPGA — no FPGA hardware needed for a GUI session). 3389
  is source-restricted to the gateway (`137.110.161.106`); no direct RDP exposure.
- **Impermanence** — yes (same as waiter: NFS `/home` + root `@blank` rollback).
- **Scratch model** — **group-level**, scoped to **E4E project groups** (KRG
  doesn't use this box, so no KRG-lab scratch): each group gets a group-owned
  `/scratch/<group>` (setgid, group-writable — collaborative, not per-user).
  Replaces the Ubuntu `/share/*` project dirs. Groups to seed: `fishsense`, `aid`,
  `huggingface`.
- **HF cache** — **shared**: `HF_HOME` → the `huggingface` group's scratch area
  (download once for everyone), overriding waiter's per-user `/local` HF cache.
- **System packages** — **match waiter** (minimal): `cifs-utils` + `gnumake` +
  `zsh` + `nix-ld` only; the Ubuntu apt pile is not replicated.
- **E4E web-deploy toolchain** — **retired from this box** (the web-deploy work
  moves elsewhere): drop GraphicsMagick-from-source, jekyll/rbenv, sshfs-to-web,
  and the `ansible_deploy_service` self-updater + Bitwarden bootstrap.

### Remaining work (a go-live blocker, not a design choice)

- **Identity migration** — all ~61 local accounts (incl. `cse237d_sp26.*` course
  accounts with expiry) must become **KRG.LOCAL AD principals** before go-live, or
  those users lose access. Don't import the old (compromised) hashes — new
  passwords. The project/lab AD groups (`fishsense`, `aid`, `huggingface`, course
  groups) must also exist, since they back both login gating and the group-level
  scratch. See [[krg-local-ad-principals-pending]] and `docs/creating-a-user.md`.

---

## Bring-up runbook (remote, via nixos-anywhere)

[nixos-anywhere](https://github.com/nix-community/nixos-anywhere) installs NixOS
onto the running Ubuntu box **over SSH**, with no ISO, USB, or console access. It
SSHes in, **kexecs into a NixOS installer in RAM** (no media), runs the disko
config (the destructive partition/ZFS step), runs `nixos-install` against the
flake, and reboots into NixOS — hands-off after launch.

> **GOTCHA — this is irreversible.** disko is destructive and not idempotent: it
> wipes and repartitions every listed device, destroying the current 3.1 TB
> btrfs root. There is no "only create what's missing".

> **GOTCHA — the box drops off the network mid-install** when it kexecs into the
> in-RAM installer; your SSH session ends and nixos-anywhere reconnects to the
> installer on its own. Don't rely on that session for anything else, and prefer
> running from a stable network / inside `tmux`.

### Pre-flight (gates — all must pass before launch)

- [ ] **Backup confirmed current** — verify `e4e-nas/2026_kastner_ml_dump` holds
      everything off the 3.1 TB btrfs root that anyone still wants. After the wipe
      it's gone.
- [ ] **by-id device names re-verified on-box** (`ls -l /dev/disk/by-id/`) and
      matched into `disko-config.nix` — disk serials are the source of truth.
- [ ] **e4e-nas `/homes` NFSv4 export + idmap** verified (see Home/root model).
- [ ] `nix flake check ./nix` passes; `nix build
      ./nix#nixosConfigurations.kastner-ml.config.system.build.toplevel` builds.
- [ ] Console/IPMI fallback identified in case the first boot needs rescue
      (GRUB `boot.debug1mounts` recovery path, per the impermanence notes).

### Install

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake ./nix#kastner-ml \
  --target-host root@kastner-ml.ucsd.edu   # the pre-NixOS box, as root (or any sudo user)
```

> **Console route (used 2026-06-15) + two gotchas it surfaced.** Installing from
> the NixOS ISO at the console (root never on the network): run disko, then
> `sudo nixos-install --root /mnt --flake 'path:<repo>/nix#kastner-ml' --no-root-passwd`.
> Use the `path:` flake ref (not `github:` or a git checkout) — it dodges both the
> flaky `api.github.com` HEAD lookup and git's "dubious ownership" check on a
> root-owned clone. Two things bit us on the first run, both now mandatory steps:
>
> 1. **Old bcache auto-assembles and holds the disks.** This box's Ubuntu root was
>    btrfs-on-bcache (8 TB HDD backing + 2 TB SSD cache). The installer kernel
>    re-assembled `bcache0` from the leftover superblocks on `sda1` + `sdb`, so
>    `zpool create` couldn't claim them (no `zfs_member` ever appeared) — and
>    disko's own wipe does NOT stop an active bcache. Tear it down FIRST:
>    `echo 1 | sudo tee /sys/block/bcache0/bcache/stop` then
>    `echo 1 | sudo tee /sys/fs/bcache/<cset-uuid>/stop`, then `wipefs -a` +
>    `sgdisk --zap-all` the three target disks (NOT the USB), THEN run disko.
>
> 2. **Export the pools before rebooting.** disko leaves `rpool`/`scratchpool`
>    imported (stamped with the *installer's* hostId) for `nixos-install`.
>    `modules/zfs.nix` sets `forceImportRoot = false`, so on first boot the
>    installed system (its own `hostId`) REFUSES to import a pool another host left
>    "active" → root never mounts → boot hangs with no network. This box has **no
>    BMC**, so that means a physical-console trip. nixos-anywhere exports for you;
>    the console route does NOT. Before reboot run `sudo zpool export -a` (or export
>    `rpool` + `scratchpool`). Recovery if already rebooted: boot the installer,
>    `zpool import -f -N <pool>; zpool export <pool>` for both pools, then reboot.

### Post-install

- [ ] Regenerate `hardware-configuration.nix` from the now-NixOS box and commit
      it (replace the placeholder).
- [ ] **Domain join** — export/install the keytab per
      [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) (NixOS
      member case: `adcli join`).
- [ ] Validate impermanence across two reboots (rollback fires; `/persist`
      preserved; `/home` mounts from e4e-nas; AD login works; 0 failed units).
- [ ] Confirm `/scratch/{fishsense,aid,huggingface}` mount + group perms (`3770`,
      setgid+sticky). Overflow is off for now (no e4e-nas cold export yet).
- [ ] Add kastner-ml to [fleet-inventory.md](fleet-inventory.md) and the
      Prometheus scrape targets (it was a not-yet-provisioned `kastner-ml` target).
