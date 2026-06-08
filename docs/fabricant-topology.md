# fabricant — storage & network topology

Reference diagrams for **fabricant**, the Proxmox VE **hypervisor** (137.110.161.98).
Unlike waiter/krg-ldap, fabricant is configured by the **Ansible** layer, not the
flake. It backs the lab's NFS (`/home` + scratch cold tier) and hosts the NixOS
VMs — notably the `krg-ldap` AD DC.

- Inventory: [`ansible/inventory/hosts.yml`](../ansible/inventory/hosts.yml) · [`host_vars/fabricant.yml`](../ansible/inventory/host_vars/fabricant.yml)
- Plays: [`ansible/playbooks/site.yml`](../ansible/playbooks/site.yml)
- Roles: [`nfs_server`](../ansible/roles/nfs_server) · [`zfs_limits`](../ansible/roles/zfs_limits) · [`proxmox_firewall`](../ansible/roles/proxmox_firewall)

> **Related:** [waiter](waiter-topology.md) · [krg-ldap](krg-ldap-topology.md). `krg-prod`
> (137.110.161.106) runs Prometheus; `waiter` (137.110.161.67) is the physical
> NFS client. Ansible currently runs **on the box** (`ansible_connection: local`).

---

## Storage

One ZFS pool, `rpool`, backs **everything**: the PVE OS root, the VM disks, and
the NFS exports. The capacity policy is *user data > VM data* — NFS gets a 20 TiB
reservation floor while the VM-disk dataset is capped, so guests can't crowd out
user data.

```mermaid
flowchart TB
  disks["4× ~15 TB drives"]
  disks --> rpool["<b>rpool</b> — RAIDZ1<br/>~37 TiB usable (~26 TiB free)<br/>zstd · atime=off · xattr=sa · posixacl"]

  subgraph ds["rpool datasets"]
    direction TB
    root["ROOT/pve-1 → /<br/>PVE OS root<br/>(holds a ~10.9 TiB waiter backup today)"]
    data["data → VM disks (zvols)<br/>quota 2T (zfs_limits)"]
    vz["var-lib-vz<br/>ISOs / templates / backups"]
    nfs["nfs → /srv/nfs<br/>reservation 20T floor · no quota<br/>(user data has priority)"]
  end

  rpool --> root & data & vz & nfs

  subgraph exp["NFSv4 exports (NFSv4-only → single tcp/2049)"]
    direction TB
    e_home["home → /srv/nfs/home<br/>fsid 11 · autosnap on"]
    e_scr["scratch-krg → /srv/nfs/scratch-krg<br/>fsid 12 · recordsize 1M · daily+ snaps"]
  end

  nfs --> e_home & e_scr

  e_home -->|"mounted as /home (rw,sync,no_root_squash)"| waiterN[["waiter 137.110.161.67<br/>NFS client"]]
  e_scr -->|"scratch cold overflow (rw,sync,no_root_squash)"| waiterN
  data -->|"backs the VM vdisk (zvol)"| ldap[["krg-ldap VM · VMID 100<br/>137.110.161.109"]]
```

| dataset | mount | role | limit |
|---|---|---|---|
| `rpool/ROOT/pve-1` | `/` | PVE OS root (+ current waiter backup) | — |
| `rpool/data` | — (zvols) | VM disks | **quota 2T** (zfs_limits) |
| `rpool/var-lib-vz` | `/var/lib/vz` | ISOs / templates / backups | (uncapped; optional 1T) |
| `rpool/nfs` | `/srv/nfs` | NFS export parent | **reservation 20T**, no quota |
| `rpool/nfs/home` | `/srv/nfs/home` | AD user homes (fsid 11) | inherits; autosnap on |
| `rpool/nfs/scratch-krg` | `/srv/nfs/scratch-krg` | waiter scratch cold overflow (fsid 12) | recordsize 1M |

> `no_root_squash` on both exports is deliberate: waiter's `pam_mkhomedir` (home)
> and the `scratch-overflow` job (scratch) run as **root** on the client and must
> create/chown files preserving owner/group. Both exports are scoped to waiter's IP only. The
> former generic `bulk` export is retired (`zfs destroy rpool/nfs/bulk` once
> confirmed empty — done out-of-band).

---

## Network

fabricant's firewall is the **Proxmox perimeter** (Ansible `proxmox_firewall`),
three nested layers. It pairs with the in-guest NixOS firewalls on the VMs — it
owns *which sources* reach a guest/host; it does not replace the guest layer. The
breach that drove this rebuild was root SSH open to `+dc/public` here; that is now
UCSD/ops-only.

```mermaid
flowchart TB
  ucsd(("UCSD nets + ops<br/>admins"))
  mon[("krg-prod 137.110.161.106<br/>Prometheus")]
  waiterC[("waiter 137.110.161.67<br/>NFS client")]
  upstream(("1.1.1.1 / campus DNS"))

  subgraph fab["fabricant — Proxmox VE host · 137.110.161.98"]
    direction TB
    subgraph fw["PVE firewall (Ansible proxmox_firewall)"]
      direction TB
      hostfw["host.fw (node-scoped, evaluated FIRST)<br/>NFSv4 tcp/2049 ← waiter only"]
      clusterfw["cluster.fw (datacenter-wide)<br/>IPSets from trusted.json<br/>… then terminal IN DROP"]
    end
    subgraph svc["host services"]
      direction LR
      psh["sshd :22"]
      web["PVE web UI :8006"]
      nodee["node-exporter :9100"]
      ipmie["ipmi-exporter :9290"]
      nfsd["nfsd :2049"]
      adcli["SSSD AD client<br/>(Domain Admins)"]
    end
    subgraph guests["VM guests — per-VM &lt;vmid&gt;.fw"]
      kl["krg-ldap (100)<br/>137.110.161.109"]
      kv["krg-vault (101)<br/>137.110.161.123"]
      kd["krg-deploy (102)<br/>137.110.161.122"]
      kp["krg-prod (103)<br/>137.110.161.106"]
    end
  end

  ucsd -->|"SSH 22 · PVE UI 8006"| clusterfw
  mon -->|"scrape 9100 / 9290 / 9000"| clusterfw
  waiterC -->|"NFS 2049"| hostfw
  fw --> svc
  adcli -.->|"identity — DC is a guest here (pending join)"| kl
  web -.->|"non-AD DNS"| upstream
```

### Inbound rules (PVE firewall)

| port | service | source | layer |
|---|---|---|---|
| 2049/tcp | NFSv4 | **waiter only** (137.110.161.67) | host.fw (first) |
| 22/tcp | SSH | `ucsd` + `ops` IPSets | cluster.fw |
| 8006/tcp | PVE web UI | `ucsd` + `ops` IPSets | cluster.fw |
| 9100/tcp | node-exporter | `krg-prod` (monitoring_host) | cluster.fw |
| 9290/tcp | ipmi-exporter | `krg-prod` | cluster.fw |
| 9000/tcp | service exporter | `krg-prod` | cluster.fw |
| — | everything else | — | **`IN DROP`** (default-deny) |

`host.fw` rules compile into `PVEFW-HOST-IN` **before** the cluster rules, so the
cluster's terminal `IN DROP` never shadows the NFS ACCEPT. IPSets (`public`,
`sealab`, `ucsd`, `ops`) are templated from the shared
[`nix/networks/trusted.json`](../nix/networks/trusted.json).

> **Bootstrap dependency:** fabricant is an SSSD AD client of `krg-ldap`, which
> runs as a VM **on fabricant itself** — so host identity depends on a guest it
> hosts. The local break-glass `krg-admin` (key-only, off AD) is the deliberate
> escape hatch. The per-VM `<vmid>.fw` files (100 krg-ldap, 101 krg-vault,
> 102 krg-deploy, 103 krg-prod) only apply if each VM's NIC has `firewall=1` set.
