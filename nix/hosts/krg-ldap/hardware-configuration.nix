# Hardware configuration for krg-ldap (Proxmox VM).
#
# Hardware section captured from the live host via
#   nixos-generate-config --show-hardware-config
#
# The boot loader below is hand-maintained: nixos-generate-config does not emit
# a boot loader, and nothing else sets one for this host.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = [];
  boot.extraModulePackages = [];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/93a68056-3a19-40c3-8954-6fa911a02341";
    fsType = "ext4";
  };

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ── Hand-maintained (not emitted by nixos-generate-config) ──────────────────
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
}
