# krg-ldap — storage & network topology

Reference diagrams for **krg-ldap**, the Samba **Active Directory domain
controller** for the new `KRG.LOCAL` forest. It is a NixOS VM (Proxmox guest
**VMID 100** on the `fabricant` hypervisor) at 137.110.161.109, configured by the
flake via [`profiles/directory.nix`](../nix/profiles/directory.nix).

- Host config: [`nix/hosts/krg-ldap/default.nix`](../nix/hosts/krg-ldap/default.nix)
- AD DC module: [`nix/modules/samba-ad.nix`](../nix/modules/samba-ad.nix)
- User runbook: [`docs/creating-a-user.md`](creating-a-user.md)

> **Related:** [waiter](waiter-topology.md) · [fabricant](fabricant-topology.md).
> krg-ldap is the identity root every other host depends on — and a **single point
> of failure** until a second DC lands (see `CLAUDE.md` pending items).

---

## Storage

krg-ldap is a plain Proxmox guest: **one virtio disk, ext4 root, GRUB on
`/dev/sda`** — no ZFS-on-root and **no impermanence** (unlike waiter). Its vdisk is
a zvol living under fabricant's capped `rpool/data`. The AD databases under
`/var/lib/samba` are created by a one-time on-box `samba-tool domain provision`
(stateful — not expressible in Nix), so they are durable VM state, **not** a flake
artifact.

```mermaid
flowchart LR
  subgraph fabricant["fabricant (Proxmox host)"]
    data["rpool/data (zvols) · quota 2T"]
  end

  subgraph vm["krg-ldap VM"]
    direction TB
    sda["/dev/sda (virtio)"] --> root["ext4 → / (GRUB on /dev/sda)"]
    root --> samba["/var/lib/samba<br/>AD SAM + Kerberos DB<br/>(created by samba-tool domain provision)"]
    root --> smbconf["/etc/samba/smb.conf<br/>(written by provision — runtime state)"]
  end

  data -->|"vdisk (zvol)"| sda
```

| path | fs | role |
|---|---|---|
| `/` | ext4 (`/dev/sda`) | OS root; vdisk = zvol on fabricant `rpool/data` |
| `/var/lib/samba` | (on `/`) | AD SAM + Kerberos DB — provisioned on-box, durable |
| `/etc/samba/smb.conf` | (on `/`) | written by provision; Nix never owns it |

---

## Network

krg-ldap serves identity (DNS, Kerberos, LDAP, SMB, Global Catalog) to the whole
fleet. Two firewall layers guard it: the **in-guest** NixOS firewall
(`samba-ad.nix` opens the AD DC port set) and the **Proxmox perimeter**
(`100.fw` / [`krg-ldap.fw`](../ansible/roles/proxmox_firewall/files/krg-ldap.fw))
which source-restricts that same set. SSH is `serviceHost` — restricted to trusted
UCSD nets in-guest. Its own resolver is **itself** (127.0.0.1 → Samba internal
DNS), forwarding non-AD queries upstream.

```mermaid
flowchart TB
  clients(("Domain members<br/>waiter, fabricant, …"))
  admins(("UCSD + ops<br/>admins"))
  mon[("krg-prod<br/>Prometheus")]
  upstream(("1.1.1.1<br/>dns forwarder"))

  subgraph perim["Proxmox perimeter — 100.fw (krg-ldap.fw)"]
    direction TB
    p["source-restricts the AD port set:<br/>SSH ← UCSD+ops<br/>DNS/Kerberos/LDAP/GC ← UCSD<br/>SMB/RPC/NetBIOS/dyn-RPC ← sealab<br/>… then IN DROP"]
  end

  subgraph vm["krg-ldap VM — ens18 · 137.110.161.109/24 · gw .1"]
    direction TB
    gfw["in-guest nftables (krg.firewall) + CrowdSec<br/>SSH 22 ← UCSD nets (serviceHost)"]
    samba["samba AD DC daemon (samba4Full)<br/>realm KRG.LOCAL · workgroup KRG<br/>SAMBA_INTERNAL DNS"]
    subgraph ports["AD DC ports (in-guest)"]
      direction LR
      a["DNS 53 · Kerberos 88/464 · LDAP 389/636<br/>Global Catalog 3268/3269 · SMB 445<br/>RPC 135/139 · NetBIOS 137/138<br/>dynamic RPC 49152-65535"]
      ne["node-exporter :9100"]
    end
  end

  clients -->|"identity: DNS · Kerberos · LDAP · SSH keys from AD"| perim
  admins -->|"SSH 22"| perim
  mon -->|"scrape 9100"| perim
  perim --> gfw
  gfw --> samba
  samba --> ports
  samba -.->|"non-AD DNS forwarded"| upstream
```

### Ports served (in-guest, restricted again at `100.fw`)

| port(s) | proto | purpose | perimeter source |
|---|---|---|---|
| 53 | tcp/udp | DNS (Samba internal) | `ucsd` |
| 88, 464 | tcp/udp | Kerberos / kpasswd | `ucsd` |
| 389, 636 | tcp (+udp 389) | LDAP / LDAPS / CLDAP | `ucsd` |
| 3268, 3269 | tcp | Global Catalog (+SSL) | `ucsd` |
| 445 | tcp | SMB | `sealab` |
| 135, 139 | tcp | RPC endpoint mapper / NetBIOS session | `sealab` |
| 137, 138 | udp | NetBIOS name / datagram | `sealab` |
| 49152-65535 | tcp | dynamic RPC (DRSUAPI, join, MMC) | `sealab` |
| 22 | tcp | SSH | `ucsd` + `ops` |
| 9100 | tcp | node-exporter | `krg-prod` |

> **Provisioning is manual & one-time.** The flake makes the box *ready* but the
> daemon stays inactive (`ConditionPathExists=/var/lib/samba/private/sam.ldb`)
> until `samba-tool domain provision` creates the forest — see the runbook in
> [`samba-ad.nix`](../nix/modules/samba-ad.nix). **SPOF:** every host's login
> depends on this single DC; the SSSD offline cache + local break-glass admins are
> the only continuity if it's down.
