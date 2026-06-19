# ARM PDK — encrypted-at-rest VeraCrypt vault

The ARM PDK is licensed, **export-controlled** IP. Its handling is governed by the
ARM agreement and a **Technology Control Plan (TCP)**. This document is the runbook
for the *storage* side of that plan — the encrypted-at-rest VeraCrypt volume and its
read-only mount on `waiter` — and maps each TCP sentence to where it is enforced.

The *access* side (RDP forced through an auditable SSH tunnel, key-only SSH) is the
companion control in [arm-pdk-tcp.md](arm-pdk-tcp.md) — `krg.xrdp.gatewayDeny`. Both
halves are enforced for `waiter` and gate on the same AD group, `ARM PDK Access`
(declared in `spec/krg-ad/groups.yml`); they bridge it into *different* local groups
via `krg.adGroupSync` — `armpdk` here (vault read access), `armpdk-rdp-deny` there (the
RDP deny set = `ARM PDK Access` ∪ sudoers ∪ wheel).

## TCP → implementation mapping

| TCP statement | Where it's enforced |
|---|---|
| "hosted on a password-controlled server … only accessible to authorized users on the TCP" | `waiter` (CSE). Login is AD/SSSD (`krg.adClient`); PDK read access is the AD group **`ARM PDK Access`**. |
| "stored in a Veracrypt volume, encrypted at rest using AES-512" | VeraCrypt container `armpdk.hc`, **AES** cipher (XTS mode → two 256-bit keys = 512-bit key material) + **SHA-512** KDF. Created per *Create the volume* below. |
| "password is securely stored in a self-hosted VaultWarden … restricted to system administrators only" | The passphrase is **never on the box** and **never in git**. It lives in the admin-only VaultWarden collection; an admin supplies it interactively at mount time. The mount tooling reads it from the tty / `systemd-ask-password` and never writes it to disk. |
| "mounted read-only by system administrators on system boot and remains mounted" | `krg.armpdkVault` (`nix/modules/security/armpdk-vault.nix`): `armpdk-mount` (or `systemctl start armpdk-vault`) run by an admin after each boot; mounts `--read-only` and stays mounted. No on-box key → no unattended auto-mount, by design. |
| "Access is restricted to authorized users through Linux group permissions … segregated access" | Mountpoint `/opt/arm-pdk` and the volume's own root dir are `root:armpdk 0750`. `armpdk` is a fixed-GID local group; AD `ARM PDK Access` members are bridged into it by `krg.adGroupSync`. |
| "remote … via SSH or RDP, RDP requiring TLS … tunneled over SSH … SSH restricted to public key" | `krg.xrdp.gatewayDeny` (`nix/modules/desktop/xrdp.nix`; see [arm-pdk-tcp.md](arm-pdk-tcp.md)) forces privileged/PDK users' RDP through a loopback SSH tunnel; xrdp TLS uses the lab-CA cert from `pki_int` (vault-agent); SSH is key-only (`ssh_hardening`). |
| "should not be used in open or public spaces …" | Operational / physical control — not enforceable in software. |

## Architecture

- **Single canonical copy on fabricant.** `armpdk.hc` lives on the ZFS dataset
  `rpool/nfs/armpdk` and is exported **read-only** over NFSv4
  (`ansible/inventory/host_vars/fabricant.yml`, `nfs_server` role).
- **waiter mounts it read-only twice over.** The NFS export mounts `ro` at
  `/srv/armpdk-src`; an admin then veracrypt-mounts `/srv/armpdk-src/armpdk.hc`
  `--read-only` at `/opt/arm-pdk`. If fabricant drops, the mount simply falls off
  (accepted — the PDK is reference data, not a boot dependency).
- **The passphrase is admin-only (VaultWarden) and never stored on waiter.** This is
  why there is **no** vault-agent render and **no** keyfile here, unlike the rest of
  the fleet's secrets: an unattended boot-mount would require an on-box key, which the
  TCP forbids.

The encrypted blob is safe to serve over a plain `sec=sys` read-only NFS export and to
snapshot — confidentiality is the VeraCrypt encryption, not the NFS/file perms.

## One-time: create the volume (on fabricant, by an admin)

> Handling export-controlled bytes — do this on fabricant in an access-controlled
> location, never copy PDK files anywhere outside the volume, and never put the
> passphrase in a shell history, a file, or a commit.

1. **Pick a passphrase and store it in VaultWarden** (admin-only collection) *first*.
   It is the only copy; if it's lost the volume is unrecoverable.

2. **Create the dataset + container.** `nfs_server` will create `rpool/nfs/armpdk` on
   the next ansible run, or create it now:

   ```bash
   zfs create -o recordsize=1M rpool/nfs/armpdk     # idempotent; ansible also ensures this
   # Size the container for the PDK with headroom. AES + SHA-512, ext4 inner FS.
   veracrypt --text --create /srv/nfs/armpdk/armpdk.hc \
     --size=<e.g. 50G> --encryption=AES --hash=SHA-512 \
     --filesystem=ext4 --volume-type=normal --pim=0 --keyfiles= --random-source=/dev/urandom
   # (enter the VaultWarden passphrase when prompted)
   ```

3. **Bake in the group ownership** (a read-only mount can't chown later, so the
   segregated-access perms must exist *inside* the volume). Mount it read-write once:

   ```bash
   veracrypt --text --mount /srv/nfs/armpdk/armpdk.hc /mnt/armpdk-rw --pim=0 --keyfiles= --protect-hidden=no
   chown root:65010 /mnt/armpdk-rw      # 65010 = the `armpdk` GID (krg.armpdkVault.gid)
   chmod 0750       /mnt/armpdk-rw
   # ... copy the PDK files in, preserving root:65010 / o-rwx ...
   chown -R root:65010 /mnt/armpdk-rw
   chmod -R o-rwx     /mnt/armpdk-rw
   veracrypt --text --dismount /mnt/armpdk-rw
   ```

   GID `65010` is used numerically because NFS `sec=sys` carries numeric ids; it must
   match `krg.armpdkVault.gid` on waiter.

4. **Permit the file to be read over the export.** The container is encrypted, so its
   own mode isn't a confidentiality control — make it readable by the squashed NFS
   client (`root_squash` → `nobody`):

   ```bash
   chmod 0644 /srv/nfs/armpdk/armpdk.hc
   ```

5. **Apply the export** (opens the dataset + NFSv4 ACL to waiter, read-only):

   ```bash
   cd ansible && ansible-playbook playbooks/site.yml --limit fabricant --tags nfs_server
   ```

## Deploy waiter

`krg.armpdkVault.enable = true` is set in `nix/hosts/waiter/default.nix`. Deploy as
usual; this adds the `ro` NFS mount of `/srv/armpdk-src`, the `armpdk` group +
adGroupSync bridge, the mountpoint, and the `armpdk-mount`/`armpdk-dismount` tools +
`armpdk-vault.service`.

## Per-boot: mount the volume (admin, after each boot)

Either the interactive wrapper:

```bash
sudo armpdk-mount        # prompts on the tty; paste the passphrase from VaultWarden
```

or the systemd unit (prompt is answerable over SSH):

```bash
sudo systemctl start armpdk-vault
# if it doesn't prompt on your terminal:
sudo systemd-tty-ask-password-agent
```

Both mount `/opt/arm-pdk` **read-only**. To unmount: `sudo armpdk-dismount` (or
`systemctl stop armpdk-vault`).

## Validate

- `mount | grep /opt/arm-pdk` shows the mount as **read-only** (`ro`).
- `ls -ld /opt/arm-pdk` → `drwxr-x--- root armpdk` (the volume's baked-in perms).
- A member of `ARM PDK Access` can read it; a non-member gets permission denied.
  Confirm the bridge resolved: `getent group armpdk` lists the AD members.
- Writes fail: `sudo touch /opt/arm-pdk/x` → read-only filesystem.
- The passphrase appears nowhere on disk (`/run`, shell history, journal) after mount.

## Notes

- **Rotating PDK content / the passphrase** is an admin task on fabricant: update (or
  recreate) `armpdk.hc`, update VaultWarden if the passphrase changed, then remount on
  waiter. There is no live-edit path — the mount on waiter is read-only by design.
- **Decommission:** drop `krg.armpdkVault.enable` + the import on waiter, remove the
  `armpdk` export from `host_vars/fabricant.yml`, and destroy `rpool/nfs/armpdk`.
