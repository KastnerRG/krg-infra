# waiter — storage & network topology

Reference diagrams for **waiter**, the KRG research/compute box (physical, AMD
Threadripper PRO 7985WX, 137.110.161.67). Everything here is derived from the
flake — the authoritative sources are linked inline; if the diagrams and the
`.nix` ever disagree, the `.nix` wins.

- Host config: [`nix/hosts/waiter/default.nix`](../nix/hosts/waiter/default.nix)
- Disk layout: [`nix/hosts/waiter/disko-config.nix`](../nix/hosts/waiter/disko-config.nix)
- Bootloader/hardware: [`nix/hosts/waiter/hardware-configuration.nix`](../nix/hosts/waiter/hardware-configuration.nix)
- Compute profile: [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) → [`base`](../nix/profiles/base.nix)

> **Related:** [fabricant](fabricant-topology.md) · [krg-ldap](krg-ldap-topology.md).
> Mermaid diagrams render inline on GitHub. `fabricant` = the Proxmox **hypervisor**
> (137.110.161.98) that serves NFS and hosts the `krg-ldap` AD DC VM
> (137.110.161.109); `krg-prod` (137.110.161.106) runs Prometheus.

---

## Storage

waiter is **ZFS-on-root with an impermanent (erase-your-darlings) root**: every
boot `nvmepool/root` is rolled back to its empty `@blank` snapshot, so durable
state must live either on a non-rolled-back dataset (`/nix`, `/persist`,
`/tools`, `/var/lib/docker`, `/local`, `scratchpool`) or be bind-mounted back from
`/persist`. User data lives **off the rolled-back root** — `/home` over NFS, and
`/scratch/krg` on its own durable `scratchpool` — so the rollback never touches it.

> **Scratch is ZFS-native, not FUSE.** `/scratch` was previously tiered by
> **autotier** (a FUSE daemon) which crashed under concurrent training reads. It's
> gone — see [scratch-greenfield.md](scratch-greenfield.md). `/scratch/krg` is now a
> plain ZFS mount on `scratchpool`: bytes on the striped HDD, hot reads served by an
> NVMe metadata (special) vdev + L2ARC; a daily job overflows cold files to NFS.

### Physical → pools → datasets

```mermaid
flowchart TB
  subgraph disks["Physical devices"]
    direction LR
    nv["4× Crucial T700 4TB NVMe<br/>(PCIe)"]
    hd["2× Seagate 16TB SATA HDD"]
    zr["zram<br/>50% RAM, zstd<br/>(swap — no on-disk swap)"]
  end

  subgraph parts["Partitioning (GPT, by-id)"]
    esp["4× 2 GiB vfat ESP<br/>(one per NVMe, independent)"]
    nvo["4× os ZFS partitions (1.4 TiB ea)"]
    nvsp["4× special ZFS partitions (128 GiB ea)"]
    nvc["4× cache ZFS partitions (1.4 TiB ea)"]
    hdz["2× whole-disk ZFS partitions (16 TB ea)"]
  end

  nv --> esp
  nv --> nvo
  nv --> nvsp
  nv --> nvc
  hd --> hdz

  esp --> grub["GRUB mirroredBoots<br/>/boot · /boot-1 · /boot-2 · /boot-3<br/>EFI fallback BOOTX64.EFI on each<br/>→ boots from any surviving NVMe"]

  nvo --> nvmepool["<b>nvmepool</b> — RAIDZ1 (1 parity)<br/>ashift=12 · autotrim · zstd · atime=off<br/>redundant: survives one NVMe loss"]
  hdz --> scratchpool["<b>scratchpool</b> — data: 2× HDD STRIPED (~29 TiB)<br/>NO redundancy (scratch is regenerable)"]
  nvsp --> scratchpool
  nvc --> scratchpool

  subgraph nvds["nvmepool datasets (legacy mounts)"]
    direction TB
    d_root["root → <b>/</b><br/>⟲ rolled back to @blank every boot"]
    d_nix["nix → /nix<br/>(never rolled back)"]
    d_persist["persist → /persist<br/>(durable · autosnap all cadences)"]
    d_tools["tools → /tools<br/>(vendor binaries · autosnap)"]
    d_docker["docker → /var/lib/docker<br/>(off rollback · autosnap off)"]
    d_local["local → /local<br/>(krg.localCache · off rollback · quota 1T)"]
  end

  subgraph spds["scratchpool layout"]
    direction TB
    sp_special["special vdev (4× NVMe, striped)<br/>metadata-only → fast listings/find"]
    sp_cache["cache / L2ARC (4× NVMe, striped)<br/>hot-read cache (LRU)"]
    sp_skrg["scratch-krg → /scratch/krg<br/>(data on HDD · 1M recsize · relatime · autosnap off)"]
    sp_se4e["scratch-e4e<br/>(mountpoint=none — reserved)"]
  end

  nvmepool --> d_root & d_nix & d_persist & d_tools & d_docker & d_local
  scratchpool --> sp_special & sp_cache & sp_skrg & sp_se4e

  d_persist -.->|"bind-mounts state back into /"| d_root
```

**`/persist` → `/` bind mounts** (what survives the rollback — see
[`modules/impermanence.nix`](../nix/modules/impermanence.nix)):
`/var/log`, `/var/lib/nixos` (uid/gid map), `/var/lib/systemd`,
`/var/lib/fail2ban` (ban DB), `/var/lib/sss` (SSSD offline cache),
`/var/lib/krg` (compose working dir + secrets + monitoring data),
`/root`, `/etc/nixos`, `/var/lib/krg-admin` (break-glass home); files
`/etc/machine-id`, the SSH host keys, `/etc/krb5.keytab` (AD membership).
(`/scratch` needs nothing here — it's on its own durable pool.)

| dataset | mount | pool | rolled back? | snapshots |
|---|---|---|---|---|
| `nvmepool/root` | `/` | nvmepool (raidz1) | **yes, → `@blank`** | off |
| `nvmepool/nix` | `/nix` | nvmepool | no | off |
| `nvmepool/persist` | `/persist` | nvmepool | no | all cadences |
| `nvmepool/tools` | `/tools` | nvmepool | no | all cadences |
| `nvmepool/docker` | `/var/lib/docker` | nvmepool | no | off |
| `nvmepool/local` | `/local` | nvmepool | no | off (quota 1T) |
| `scratchpool/scratch-krg` | `/scratch/krg` | scratchpool (HDD stripe + NVMe special/L2ARC) | no | **off** (regenerable; see note) |

> Scratch snapshots are **off on purpose**: the data is regenerable, and snapshots
> would pin blocks the overflow job frees when it demotes a file to NFS. The cold
> copies on fabricant NFS *are* snapshotted (ansible `nfs_server`), so archived data
> still has accidental-delete protection.

### Logical view — what users see (`/home`, `/scratch`, `/local`)

```mermaid
flowchart LR
  user(("AD user<br/>session"))

  subgraph waiter["waiter (local)"]
    home["/home/&lt;user&gt;<br/>(NFS mount, AD home)"]
    scratch["/scratch/krg<br/><b>plain ZFS mount</b> (no FUSE)<br/>owned by 'Kastner Research Group' (3770 setgid+sticky)<br/>per-user /scratch/krg/&lt;user&gt;"]
    local["/local/&lt;user&gt;<br/>node-local NVMe cache (0700)<br/>~/.vscode-server, ~/.cursor-server (symlinks)<br/>XDG_CACHE_HOME, HF_HOME, torch, conda-pkgs, npm"]
  end

  subgraph readpath["how a /scratch read is served (in-kernel ZFS, no daemon)"]
    direction LR
    r1["① ARC (RAM)"]
    r2["② L2ARC (NVMe cache)"]
    r3["③ HDD stripe (data home)"]
    r1 --> r2 --> r3
  end

  user --> home
  user --> scratch
  user --> local

  scratch --> readpath

  scratch -.->|"overflow: daily — idle &gt;6mo, or coldest when &gt;85% full<br/>copy→verify→symlink (scratch-restore brings back)"| cold[("fabricant NFS<br/>137.110.161.98:/srv/nfs/scratch-krg<br/>→ /srv/scratch-cold/krg")]
  home -.->|"NFSv4.2 (hard,nofail,nconnect=4)"| fab[("fabricant<br/>137.110.161.98<br/>rpool/nfs/home<br/>→ /srv/nfs/home")]
  local --> nvl[("nvmepool/local<br/>(pure NVMe, no FUSE/NFS)")]
```

Notes:
- **`/scratch/krg`** is a plain ZFS mount ([`scratch.nix`](../nix/modules/scratch.nix))
  on `scratchpool` — no FUSE daemon in the read path. ZFS serves hot reads from RAM
  (ARC) then NVMe (L2ARC); the bytes live on the striped HDD; metadata is on the NVMe
  special vdev. The daily `scratch-overflow` timer demotes files to fabricant NFS for two
  reasons (both by last-access): a **TTL sweep** moves anything not accessed in 6 months
  even when there's free space, and a **capacity sweep** moves the coldest files when the
  pool passes 85% (down to 75%). A demoted file becomes a symlink (reads still work over
  the network); `scratch-restore <path>` pulls it back. It **fails
  closed**: if the cold NFS area is down the unit won't start, and a local file is never
  unlinked until its NFS copy is verified. See [scratch-greenfield.md](scratch-greenfield.md).
  Each member also gets a private `/scratch/krg/<user>` and a convenience **`~/scratch`**
  symlink to it, both laid on login (the symlink never clobbers a real `~/scratch`).
- **`/home`** is a plain `nofail` NFSv4.2 mount ([`nfs-home.nix`](../nix/modules/nfs-home.nix)),
  pinned to fabricant by IP so it never waits on DNS. A PAM **login gate** denies
  any AD user whose home is under `/home` while that mount is down — closing the
  impermanence data-loss window. Break-glass `krg-admin` (home `/var/lib/krg-admin`)
  is unaffected and keeps the box recoverable.
- **`/local`** ([`local-cache.nix`](../nix/modules/local-cache.nix)) is the
  deliberately boring counterpart: pure local NVMe for hot, watch-heavy,
  regenerable state that has no business on NFS. The symlink is never created over
  an existing real `~/.vscode-server`.

---

## Network

waiter is **physical with a public UCSD IP** — there is no Proxmox perimeter in
front of it (that layer only guards VMs). Its single defense layer is the in-guest
nftables firewall ([`krg.firewall`](../nix/modules/security/firewall.nix)) plus
key-only SSH and fail2ban. SSH is intentionally open to the world (compute hosts
serve researchers from anywhere); RDP and the monitoring ports are restricted.

```mermaid
flowchart TB
  net(("Internet /<br/>UCSD campus"))
  mon[("krg-prod<br/>137.110.161.106<br/>Prometheus")]

  subgraph wn["waiter — eno1np0 · 137.110.161.67/24 · gw 137.110.161.1"]
    direction TB
    fw["nftables firewall (krg.firewall)<br/>+ CrowdSec ssh-bf + CAPI blocklists<br/>(nftables bouncer; whitelist: ucsd, sealab, ops, machines)"]
    subgraph svcs["listening services"]
      direction LR
      ssh["sshd :22<br/>key-only · ed25519-only"]
      rdp["xrdp :3389<br/>(only if FPGA/XRDP on — currently OFF)"]
      m_node["node-exporter :9100"]
      m_ipmi["ipmi-exporter :9290"]
      m_dkr["docker metrics :9323"]
      m_cli["prometheus client :9000"]
      m_dcgm["DCGM exporter :9400 (Docker, GPU)"]
    end
  end

  ad[("krg-ldap (DC)<br/>137.110.161.109<br/>realm KRG.LOCAL")]
  fab[("fabricant<br/>137.110.161.98<br/>NFS exports")]
  ext(("github / nix cache"))

  net -->|"TCP 22 (open to all)"| fw
  net -->|"TCP 3389 — UCSD nets only, when enabled"| fw
  mon -->|"scrape 9100/9290/9323/9000/9400<br/>(source-restricted to krg-prod)"| fw
  fw --> svcs

  wn -->|"AD/SSSD: Kerberos, LDAP, SSH keys from AD<br/>+ primary DNS for krg.local zone"| ad
  wn -->|"NFSv4.2: /home + /scratch cold overflow"| fab
  wn -->|"nightly auto-upgrade (flake) + builds"| ext
```

### Inbound rules

| port | service | exposure | source |
|---|---|---|---|
| 22/tcp | SSH | **open to all** | any (key-only ed25519 + CrowdSec) |
| 3389/tcp | XRDP | only when `krg.fpga.enable` (currently **off**) | UCSD nets (`rdpSources`) |
| 9100/tcp | node-exporter | monitoring | `krg-prod` only |
| 9290/tcp | ipmi-exporter | monitoring | `krg-prod` only |
| 9323/tcp | docker metrics | monitoring | `krg-prod` only |
| 9000/tcp | prometheus client | monitoring | `krg-prod` only |
| 9400/tcp | DCGM GPU exporter | monitoring | `krg-prod` only |

Monitoring source = `trusted.json` `monitoring_host` (137.110.161.106). Trusted
nets (`ucsd`/`sealab`/`ops`) live in
[`nix/networks/trusted.json`](../nix/networks/trusted.json), shared with the
Ansible layer.

### Outbound dependencies

| target | purpose | how |
|---|---|---|
| `krg-ldap` 137.110.161.109 | AD membership: login, SSH keys, sudo, internal DNS | SSSD (Kerberos/LDAP); DC pinned as **primary nameserver** |
| `fabricant` 137.110.161.98 | `/home` + `/scratch/krg` cold overflow | NFSv4.2 (`hard,nofail,nconnect=4`) |
| `132.239.0.252`, `8.8.8.8`, `1.1.1.1` | fallback DNS (after the DC) | resolv.conf |
| github / nix binary cache | nightly `system.autoUpgrade` (04:00) + builds | https |

> **SPOF:** every login depends on the single `krg-ldap` DC; the SSSD offline
> cache + local `krg-admin` are the only continuity if it's down. A second DC is a
> tracked follow-up (see `CLAUDE.md` pending items).
