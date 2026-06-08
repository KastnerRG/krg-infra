# Replace this file with the output of:
#   nixos-generate-config --show-hardware-config
# Run on the e4e-prod host after booting the NixOS installer.
{modulesPath, ...}: {
  imports = [(modulesPath + "/profiles/qemu-guest.nix")];

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda"; # adjust to actual disk
  };

  fileSystems."/" = {
    device = "/dev/sda1"; # adjust
    fsType = "ext4";
  };

  swapDevices = [];

  # Adjust to match actual CPU cores
  nix.settings.max-jobs = 4;
}
