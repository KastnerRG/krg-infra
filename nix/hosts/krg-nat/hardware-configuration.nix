# Hardware configuration for krg-nat (Proxmox VM) — ZFS-on-root via disko.
#
# SCAFFOLD — the values marked REPLACE/CONFIRM below are filled from the live VM
# after first boot:
#   nixos-generate-config --show-hardware-config
# Keep the disko/ZFS/bootloader scaffolding; splice in the captured
# `boot.initrd.availableKernelModules` and `max-jobs`. Filesystems are NOT declared
# here — disko (./disko-config.nix) is the single authority for `fileSystems.*`
# (root/nix/persist/boot/var-lib-incus).
#
# FIRMWARE — **legacy BIOS (SeaBIOS) + GRUB**, matching krg-prod / e4e-prod (no
# UEFI/OVMF). disko provides a 1 MiB BIOS-boot partition + an ext4 /boot; GRUB
# installs to the whole disk (below).
{
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  # CONFIRM against the captured config (Proxmox virtio-scsi is the common case).
  boot.initrd.availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = [];
  boot.extraModulePackages = [];

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ── ZFS-on-root support (disko owns the layout; see ./disko-config.nix) ──────
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.devNodes = "/dev/disk/by-id"; # match disko's by-id device paths
  # Single-consumer VM pool: force-import the root pool so a hostId mismatch can't
  # wedge boot into emergency mode. No other system could be using this disk, so the
  # split-brain protection `false` buys is moot here.
  boot.zfs.forceImportRoot = true;

  # ZFS requires a unique 8-hex-digit host id (else import refuses). Random + stable,
  # generated off-box; uniqueness across the fleet is all that matters (distinct from
  # e4e-prod's 3aecba9f, krg-prod's, etc.).
  networking.hostId = "b3f9a1c7";

  # ── Boot loader: legacy-BIOS GRUB to the whole disk (matches krg-prod). disko's
  # EF02 BIOS-boot partition holds core.img; /boot is the ext4 partition. disko
  # itself populates `boot.loader.grub.devices` from disko-config (the disk with the
  # BIOS-boot partition) — so we only flip enable + efiSupport here; adding the
  # device again would duplicate it ("duplicated devices in mirroredBoots"). ──────
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  nix.settings.max-jobs = lib.mkDefault 4; # CONFIRM against the VM's vCPU count
}
