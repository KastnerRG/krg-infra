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

A single-GPU lab compute node, sibling to **waiter** but smaller and with a
fundamentally different disk topology (3 heterogeneous disks, **no redundancy
possible** — one of each kind).

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
the same perimeter posture as waiter: key-only SSH + fail2ban, in-guest firewall,
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
break-glass `krg-admin` (home `/var/lib/<account>`, off `/home`) keeps the box
recoverable while NFS is down.

---

## Host integration (the rest of "pull into the fleet")

To land in one PR alongside the disko file:

1. **`nix/hosts/kastner-ml/disko-config.nix`** — the layout above.
2. **`nix/hosts/kastner-ml/hardware-configuration.nix`** — generated on-box at
   first deploy (`nixos-generate-config --show-hardware-config`); placeholder
   until then.
3. **`nix/hosts/kastner-ml/default.nix`** — imports `profiles/compute.nix` minus
   FPGA/XRDP (this is a GPU-only box, no FPGA hardware), plus:
   - `krg.nvidia` for the single RTX A6000 (+ `cudaAccessGroups`, DCGM exporter).
   - `krg.localCache` (`/local`, **quota 500G** — chosen over waiter's 1T because
     the 2 TB SSD also holds nix store + CUDA Docker images).
   - `krg.scratch` (krg lab, `/scratch/krg`, overflow → e4e-nas NFS).
   - `krg.nfsHome` → e4e-nas `/homes`, `requireMountForLogin` on (default).
   - `krg.adClient` (KRG.LOCAL; widen `allowedGroups` for lab users as on waiter).
4. **`nix/flake.nix`** — add `kastner-ml` under `nixosConfigurations`.
5. **Perimeter** — `eno1` is public; same key-only + fail2ban posture as waiter.
   If it ever exposes a Docker-published port for remote scraping (e.g. DCGM
   9400), add the `DOCKER-USER`/nftables FORWARD restriction matching the ingress
   interface (`eno1`) — the standing waiter caveat.

> `git add` the new files before `nix flake check ./nix` — a flake only sees
> git-tracked files.

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
  --target-host c.crutchfield.642@kastner-ml.ucsd.edu
```

### Post-install

- [ ] Regenerate `hardware-configuration.nix` from the now-NixOS box and commit
      it (replace the placeholder).
- [ ] **Domain join** — export/install the keytab per
      [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) (NixOS
      member case: `adcli join`).
- [ ] Validate impermanence across two reboots (rollback fires; `/persist`
      preserved; `/home` mounts from e4e-nas; AD login works; 0 failed units).
- [ ] Confirm `/scratch/krg` mounts, lab perms (`3770`, setgid+sticky), and the
      overflow timer targets e4e-nas.
- [ ] Add kastner-ml to [fleet-inventory.md](fleet-inventory.md) and the
      Prometheus scrape targets (it was a not-yet-provisioned `kastner-ml` target).
