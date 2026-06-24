# Hardware configuration for e4e-prod (Proxmox VM) — ZFS-on-root via disko.
#
# SCAFFOLD — the values marked REPLACE/CONFIRM below are filled from the live VM
# after first boot:
#   nixos-generate-config --show-hardware-config
# Keep the disko/ZFS/bootloader scaffolding here; splice in the captured
# `boot.initrd.availableKernelModules`, `networking.hostId`, and `max-jobs`.
# Filesystems are NOT declared here — disko (./disko-config.nix) is the single
# authority for `fileSystems.*` (root/nix/persist/boot/var-lib-docker).
#
# FIRMWARE — **legacy BIOS (SeaBIOS) + GRUB**, matching krg-prod and the other lab
# VMs (no UEFI/OVMF). disko provides a 1 MiB BIOS-boot partition + an ext4 /boot;
# GRUB installs to the whole disk (below).
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
  boot.zfs.forceImportRoot = false; # safer (26.11 default); rpool has a single consumer

  # ZFS requires a unique 8-hex-digit host id (else import refuses). Random + stable
  # (generated off-box; uniqueness across the fleet is all that matters).
  networking.hostId = "3aecba9f";

  # ── Boot loader: legacy-BIOS GRUB to the whole disk (matches krg-prod). disko's
  # EF02 BIOS-boot partition holds core.img; /boot is the ext4 partition. disko
  # itself populates `boot.loader.grub.devices` from disko-config (the disk with
  # the BIOS-boot partition) — so we only flip enable + efiSupport here; adding the
  # device again would duplicate it ("duplicated devices in mirroredBoots"). ──────
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  nix.settings.max-jobs = lib.mkDefault 4; # CONFIRM against the VM's vCPU count
}
