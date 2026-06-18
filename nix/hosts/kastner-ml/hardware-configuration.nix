# kastner-ml — hardware bits ONLY. Storage is owned elsewhere:
#   - partitions / pools / datasets / fileSystems  -> disko-config.nix
#   - ZFS knobs (devNodes, supportedFilesystems)   -> modules/zfs.nix
#   - rollback + persistence                       -> modules/impermanence.nix
#
# GOTCHA — regenerating this file. When you run
#   nixos-generate-config --show-hardware-config
# on the real kastner-ml, copy in ONLY the hardware lines
# (boot.initrd.*KernelModules, microcode, max-jobs). Do NOT paste the `fileSystems.*`,
# `swapDevices`, or `boot.loader.*` it emits — disko declares the filesystems, swap is
# zram (hosts/kastner-ml/default.nix), and the bootloader is set below. Pasting them
# produces duplicate-definition conflicts.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  # ---- bootloader: GRUB EFI on the single ESP (the SSD) ----
  # One OS disk, so a single boot (no waiter-style mirroredBoots). efiInstallAsRemovable
  # writes the EFI fallback path (\EFI\BOOT\BOOTX64.EFI) on the ESP so firmware boots
  # without depending on NVRAM entries — which is why canTouchEfiVariables is false.
  # GRUB only reads the vfat /boot, never the ZFS pool; copyKernels is required because
  # /boot is vfat (no symlinks into the Nix store); configurationLimit bounds how many
  # generations' kernels sit on the 2G ESP. Secure Boot is disabled on this box.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    copyKernels = true;
    configurationLimit = 10;
    device = "nodev";
  };
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.efi.efiSysMountPoint = "/boot";

  # ---- hardware lines from `nixos-generate-config` on the real kastner-ml ----
  # SATA (HDD + SSD) + NVMe (Optane) x86_64 server.
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "ehci_pci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"]; # Intel Xeon E5-1650 v4 (6C/12T)
  boot.extraModulePackages = [];

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  # No disk swap — swap is zram (hosts/kastner-ml/default.nix). Explicit so a stray
  # generate-config swapDevices paste stands out as a conflict.
  swapDevices = [];

  # 12-thread box — modest bump for build throughput.
  nix.settings.max-jobs = 8;
}
