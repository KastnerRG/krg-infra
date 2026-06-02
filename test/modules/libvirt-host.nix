# NixOS module for the DSM test-rig host (your dev laptop).
#
# Enables libvirt/KVM with UEFI (OVMF) + software TPM (swtpm) + virt-manager so the
# XPEnology DSM VMs (DS3622xs+ / broadwellnk, DSM 7.3 — see ../README.md) can be
# declared and driven from this repo instead of clicked together.
#
# Import into your laptop's NixOS configuration, e.g.:
#   imports = [ inputs.krg-rig.nixosModules.libvirt-host ];
#   krg.dsmRig = { enable = true; user = "chris"; };
{ config, lib, pkgs, ... }:
let
  cfg = config.krg.dsmRig;
in {
  options.krg.dsmRig = {
    enable = lib.mkEnableOption "DSM test-rig virtualization host (libvirt/KVM/OVMF/swtpm)";

    user = lib.mkOption {
      type = lib.types.str;
      example = "chris";
      description = "User added to the libvirtd + kvm groups so it can drive the rig VMs without sudo.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true; # software TPM — some DSM 7 / loader paths expect one
        ovmf = {
          enable = true; # UEFI firmware for the guests
          packages = [ pkgs.OVMFFull.fd ];
        };
      };
    };

    # GUI management (per the spec); virsh + the rest live in the devShell.
    programs.virt-manager.enable = true;

    # Operator drives VMs without sudo.
    users.users.${cfg.user}.extraGroups = [ "libvirtd" "kvm" ];

    # Nested KVM so DSM-in-KVM behaves; the non-matching vendor line is ignored.
    boot.extraModprobeConfig = ''
      options kvm_intel nested=1
      options kvm_amd nested=1
    '';

    environment.systemPackages = with pkgs; [ virtiofsd ];
  };
}
