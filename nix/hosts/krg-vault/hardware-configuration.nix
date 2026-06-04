# Hardware configuration for krg-vault (Proxmox VM).
#
# Hardware section captured from the live host via
#   nixos-generate-config --show-hardware-config
# Stripped from that output: the envfs `/bin` bind (provided by
# modules/security/oec-qualys-trellix.nix, not hardware).
#
# The boot loader and max-jobs below are hand-maintained: nixos-generate-config
# does not emit a boot loader, and nothing else sets one for this host.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/91c76e90-08c0-4493-b7a8-45fa107a01d7";
    fsType = "ext4";
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ── Hand-maintained (not emitted by nixos-generate-config) ──────────────────
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
  nix.settings.max-jobs = 16;
}
