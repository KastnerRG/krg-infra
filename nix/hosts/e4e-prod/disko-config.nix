# Disk layout for e4e-prod (declarative, via disko) — ZFS-on-root, single virtual
# disk, impermanence-ready. See docs/e4e-prod-tenant-platform.md + ADR 0008.
#
# CONTEXT — e4e-prod is a Proxmox VM (guest on fabricant): the student-project
# tenant platform. It runs ZFS-on-root so it can carve a per-tenant ZFS *zvol* for
# each tenant microVM, keeping the platform self-contained — a new tenant is one
# `krg.tenants` declaration, with no hypervisor-layer disk provisioning. Because
# fabricant is itself ZFS, this is NESTED ZFS (ZFS-on-ZFS): tuned to avoid the
# double penalty — a small inner ARC (set in hosts/e4e-prod/default.nix), a single
# vdev (fabricant already provides redundancy), and `primarycache=metadata` on the
# bulk tenant-data parent so data isn't cached twice over fabricant's ARC. See
# ADR 0004 (VM IO budget) + ADR 0008.
#
# GOTCHA — disko is DESTRUCTIVE and not idempotent. `disko --mode disko` (or
# nixos-anywhere) WIPES and repartitions the device below every run. Run it ONCE
# at install; on later boots use `--mode mount` (import + mount only). Treat this
# file as "what the disk WILL be made to look like".
#
# GOTCHA — device path. A Proxmox VM has ONE virtual disk. Fill REPLACE-ROOT-DISK
# from `ls -l /dev/disk/by-id/` on the booted VM:
#   virtio-scsi  ->  scsi-0QEMU_QEMU_HARDDISK_drive-scsi0  or  wwn-0x...
#   virtio-blk   ->  virtio-<serial>
# Use by-id (NOT /dev/sda|vda): those names reshuffle across controller/slot
# enumeration and ZFS would fail to import. Matches boot.zfs.devNodes.
{...}: let
  espSize = "1G"; # vfat ESP; holds the bootloader + ZFS initrds (chunky) for a few generations

  # Pool-root props inherited by every dataset. lz4 (light — nested ZFS, keep CPU
  # low and let it early-abort on incompressible data); atime off; xattr=sa +
  # posixacl (AD/NFS-friendly); auto-snapshot OFF by default (datasets opt in).
  # primarycache stays `all` for the OS datasets; the tenant-data parent overrides
  # to `metadata` (the nested-ZFS double-cache tuning).
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
      device = "/dev/disk/by-id/REPLACE-ROOT-DISK"; # <- fill from the booted VM (see header)
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = espSize;
            type = "EF00"; # EFI System — UEFI enumerates it as bootable
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = ["umask=0077" "nofail"];
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
        # Root — rolled back to @blank every boot by modules/impermanence.nix.
        # @blank is captured EMPTY here (disko runs this hook right after `zfs
        # create`, before nixos-install). CAVEAT (waiter, systemd 258): an empty
        # root has no /usr and PID1 freezes ("/usr/ is not populated") before
        # tmpfiles runs — modules/impermanence.nix reseeds /usr/bin/env in initrd
        # so an empty @blank still boots. The `zfs list` guard keeps `--mode mount`
        # re-runs from erroring.
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "false"; # rolled back, never snapshotted
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

        # Survives the rollback. modules/impermanence.nix (in default.nix) binds the
        # durable paths here: host keys, machine-id, the vault-agent secret-zero
        # (/var/lib/krg/openbao-agent), and the edge cert-manager's acme.json — so
        # Let's Encrypt certs are NOT re-issued on every boot (the rate-limit
        # invariant, ADR 0008).
        persist = {
          type = "zfs_fs";
          mountpoint = "/persist";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "true"; # frequent+hourly+daily+weekly+monthly
        };

        # Edge Docker state (the platform Traefik + Authentik outpost stack). On its
        # own dataset so image/layer churn stays off /persist's snapshots, and it's
        # durable independent of the root rollback (a real mount, not a persist bind).
        # Snapshots OFF — images are pullable, overlay2 layers aren't worth snapping.
        docker = {
          type = "zfs_fs";
          mountpoint = "/var/lib/docker";
          options.mountpoint = "legacy";
          options."com.sun:auto-snapshot" = "false";
        };

        # Parent container for the per-tenant microVM zvols. The krg.tenants module
        # creates `rpool/tenants/<name>` zvols under here — one durable block device
        # per tenant VM (DEPLOY_DIR + Postgres), with its own quota + snapshots set
        # on the zvol. mountpoint=none: this is a container, not a mount. The zvols
        # are created by the module (added over time), NOT by disko.
        # primarycache=metadata: tenant bulk data is already cached by fabricant's
        # ARC, so the inner ARC caches only metadata here (nested-ZFS tuning).
        tenants = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            primarycache = "metadata";
            "com.sun:auto-snapshot" = "false"; # per-tenant zvols set their own
          };
        };
      };
    };
  };
}
