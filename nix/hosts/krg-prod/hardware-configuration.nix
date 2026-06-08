# Hardware configuration for krg-prod (Proxmox VM).
#
# Hardware section captured from the live host via
#   nixos-generate-config --show-hardware-config
# Stripped from that output: the envfs `/bin` bind (provided by
# modules/security/oec-qualys-trellix.nix, not hardware) and the live
# `/var/lib/docker/overlay2/.../merged` container mounts (ephemeral runtime).
#
# The boot loader and max-jobs below are hand-maintained: nixos-generate-config
# does not emit a boot loader, and nothing else sets one for this host.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  boot.initrd.availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = [];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/1855a5cd-fd1a-458e-b167-f3d813da7adf";
    fsType = "ext4";
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ── Hand-maintained (not emitted by nixos-generate-config) ──────────────────
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
  nix.settings.max-jobs = 4;
}
