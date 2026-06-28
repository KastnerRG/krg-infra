# Disk layout for krg-nat (declarative, via disko) — ZFS-on-root, single virtual
# disk, impermanence-ready. See ADR 0017 (Incus/NAT self-serve platform).
#
# CONTEXT — krg-nat is a Proxmox VM (guest on fabricant): the phase-1 Incus
# platform host. It runs the Incus daemon; tenant instances (self-serve VMs and
# tenant services) are Incus instances on its internal NAT. Instance disks live on
# the `dir` storage pool under /var/lib/incus (its own dataset below) — deliberately
# NOT a nested zpool: ZFS-on-ZFS is rejected by ADR 0004 (double ARC / write
# penalty), so the inner pool is a single vdev and instance volumes are plain files
# on it. Size the Proxmox VM's virtual disk generously — it holds every tenant's
# disk.
#
# GOTCHA — disko is DESTRUCTIVE and not idempotent. `disko --mode disko` (or
# nixos-anywhere) WIPES and repartitions the device below every run. Run it ONCE at
# install; on later boots use `--mode mount`. Treat this file as "what the disk WILL
# be made to look like".
#
# DEVICE — CONFIRM at install (`ls -l /dev/disk/by-id/`). Mirrors the other lab VMs:
# a single VirtIO SCSI disk on scsi0, by-id `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`
# (the default QEMU id when no disk serial is set — stable for a single-disk VM).
# Use by-id (NOT /dev/sda): the kernel name reshuffles across controller enumeration
# and ZFS would fail to import. Matches boot.zfs.devNodes.
#
# FIRMWARE — **legacy BIOS (SeaBIOS) + GRUB**, matching krg-prod / e4e-prod and the
# other lab VMs (no UEFI/OVMF). GPT disk → a 1 MiB BIOS-boot partition (EF02) for
# GRUB's core.img + a plain ext4 /boot; GRUB installs to the whole disk
# (hardware-configuration.nix). /boot is its own partition (NOT a ZFS dataset), so it
# sits outside any future impermanence rollback.
{...}: let
  bootSize = "1G"; # ext4 /boot — GRUB reads kernels/initrds here (ZFS initrd is chunky)

  # Pool-root props inherited by every dataset. lz4 (light — nested ZFS, keep CPU low
  # and let it early-abort on incompressible data); atime off; xattr=sa + posixacl
  # (AD/NFS-friendly); auto-snapshot OFF by default (datasets opt in).
  zfsRootProps = {
    mountpoint = "none"; # pool root never mounts; children opt in
    compression = "lz4";
    atime = "off";
    xattr = "sa";
    acltype = "posixacl";
    "com.sun:auto-snapshot" = "false";
  };
in {
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"; # CONFIRM at install (see header)
      content = {
        type = "gpt";
        partitions = {
          # 1 MiB BIOS-boot partition — GRUB embeds core.img here (required for
          # legacy-BIOS GRUB on a GPT disk). No filesystem, no mountpoint.
          bios = {
            size = "1M";
            type = "EF02";
          };
          # Plain ext4 /boot (GRUB reads kernels/initrds). Own partition, off the
          # ZFS root, so a future impermanence rollback never touches it.
          boot = {
            size = bootSize;
            type = "8300"; # Linux filesystem
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/boot";
              mountOptions = ["nofail"];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      mode = ""; # single vdev — NO redundancy (fabricant's pool provides it; nested ZFS)
      options = {
        ashift = "12"; # 4K sectors; permanent for the vdev
        autotrim = "on"; # the virtual disk is NVMe-backed on fabricant
      };
      rootFsOptions = zfsRootProps;

      datasets = {
        # Root — impermanence-ready (rolled back to @blank every boot IF
        # modules/impermanence.nix is enabled in default.nix; like e4e-prod it is
        # scaffolded here but not yet enabled). @blank is captured EMPTY here (disko
        # runs this hook right after `zfs create`, before nixos-install).
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "false";
          postCreateHook = ''
            zfs list -t snapshot -H -o name | grep -qx 'rpool/root@blank' \
              || zfs snapshot rpool/root@blank
          '';
        };

        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "false"; # store is reproducible
        };

        # Survives any future rollback. modules/impermanence.nix (when enabled) binds
        # the durable paths here: host keys, machine-id, the vault-agent secret-zero.
        persist = {
          type = "zfs_fs";
          mountpoint = "/persist";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "true"; # frequent+hourly+daily+weekly+monthly
        };

        # Incus state + the `dir` storage pool (every tenant instance's disk lives
        # under /var/lib/incus/storage-pools/<pool>). Its own dataset so instance
        # image/volume churn stays off /persist's snapshots and it's durable
        # independent of any root rollback (a real mount, not a persist bind) — the
        # same pattern krg-prod/e4e-prod use for /var/lib/docker. Snapshots OFF:
        # snapshotting a dir pool of instance disk-images is heavy and pointless —
        # tenant data is backed up via the ADR 0017 Temporal pattern, ephemeral
        # self-serve VMs hold nothing durable, and instances rebuild from the golden
        # template.
        incus = {
          type = "zfs_fs";
          mountpoint = "/var/lib/incus";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "false";
        };
      };
    };
  };
}
