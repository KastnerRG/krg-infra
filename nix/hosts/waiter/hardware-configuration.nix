# waiter — hardware bits ONLY. Everything storage-related is owned elsewhere:
#   - partitions / pools / datasets / fileSystems  -> disko-config.nix (disko
#     generates config.fileSystems for /, /nix, /persist, /tools and the four
#     mirrored ESP mounts /boot, /boot-1, /boot-2, /boot-3)
#   - ZFS knobs (devNodes, supportedFilesystems, hostId-consuming bits) -> modules/zfs.nix
#   - rollback + persistence                       -> modules/impermanence.nix
#
# GOTCHA — regenerating this file. When you run
#   nixos-generate-config --show-hardware-config
# on the real waiter, copy in ONLY the hardware lines (boot.initrd.*KernelModules,
# microcode, max-jobs). Do NOT paste the `fileSystems.*`, `swapDevices`, or
# `boot.loader.*` it emits: disko already declares the filesystems, swap is zram
# (see hosts/waiter/default.nix), and the bootloader is set below. Pasting them
# produces duplicate-definition conflicts.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  # ---- bootloader: GRUB with a mirrored ESP across all four NVMe ----
  # systemd-boot can't install onto a software-RAID ESP (bootctl needs a real GPT
  # partition, not an md device — that was the "/dev/md127 is not located on a
  # partitioned block device" failure). So the ESP is four independent vfat
  # partitions (disko-config.nix) and GRUB is installed to every one.
  # efiInstallAsRemovable writes the EFI fallback path (\EFI\BOOT\BOOTX64.EFI) on
  # each ESP, so firmware boots from whichever disk survives WITHOUT depending on
  # NVRAM boot entries — which is also why canTouchEfiVariables must be false.
  # GRUB only ever reads the vfat /boot, never the ZFS pool, so there's no
  # zpool-feature-flag fragility and we deliberately don't set grub.zfsSupport.
  # copyKernels is required because /boot is vfat (can't symlink into the Nix
  # store); configurationLimit bounds how many generations' kernels sit on the 2G ESP.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    copyKernels = true;
    configurationLimit = 10;
    mirroredBoots = [
      {
        path = "/boot";
        efiSysMountPoint = "/boot";
        devices = ["nodev"];
      }
      {
        path = "/boot-1";
        efiSysMountPoint = "/boot-1";
        devices = ["nodev"];
      }
      {
        path = "/boot-2";
        efiSysMountPoint = "/boot-2";
        devices = ["nodev"];
      }
      {
        path = "/boot-3";
        efiSysMountPoint = "/boot-3";
        devices = ["nodev"];
      }
    ];
  };
  # Required with efiInstallAsRemovable (and we can't touch NVRAM on a mirrored ESP).
  boot.loader.efi.canTouchEfiVariables = false;

  # ---- placeholders: replace with real `nixos-generate-config` output ----
  # These are reasonable defaults for an NVMe + SATA x86_64 server; the root pool
  # only needs `nvme` (+ zfs, pulled in by modules/zfs.nix) in initrd.
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-amd"]; # AMD Ryzen Threadripper PRO 7985WX (64C/128T)
  boot.extraModulePackages = [];

  # Microcode (generate-config sets this; harmless default until then).
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;

  # No disk swap — swap is zram (hosts/waiter/default.nix). Kept explicit so a
  # stray generate-config swapDevices paste stands out as a conflict.
  swapDevices = [];

  # 64C/128T box — raised for build throughput. `cores` stays at the default
  # (0 = a single build may use all threads), so big local builds run full-speed.
  # This is a multi-user compute host: if a nightly autoUpgrade rebuild ever
  # starves running jobs, bound per-build width with `nix.settings.cores`.
  nix.settings.max-jobs = 32;
}
