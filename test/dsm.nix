# Pinned DSM rig inputs + the VM launchers.
#
# Pins (sha256 from `nix-prefetch-url`): the RR loader release and the DSM 7.3.2
# DS3622xs+ .pat. Pinning both keeps the rig from silently drifting to a newer DSM
# than prod — that's the point (ADR 0001 / docs/krg-prod-iac.md). Bump deliberately.
#
# Two launchers:
#   dsm-vm        — via libvirt (qemu:///system); needs the krg.dsmRig host module.
#                   For hosts/CI managed with that module (declarative domain XML).
#   dsm-vm-qemu   — direct QEMU; NO libvirtd, NO NixOS module. Runs on any machine
#                   with Nix + /dev/kvm access. Use this if your machine isn't managed
#                   by this repo.
{ pkgs }:
let
  # RR loader (RROrg/rr) — supports broadwellnk on DSM 7.3.
  rrLoaderZip = pkgs.fetchurl {
    url = "https://github.com/RROrg/rr/releases/download/26.4.0/rr-26.4.0.img.zip";
    sha256 = "0likw579hixj88l6il0rm33cdfzj4zwxbc6xg07spzhcnlpmkril";
  };

  # DSM 7.3.2-86009 install image for DS3622xs+ (the emulated model). 399.61 MB.
  dsmPat = pkgs.fetchurl {
    url = "https://global.synologydownload.com/download/DSM/release/7.3.2/86009/DSM_DS3622xs%2B_86009.pat";
    sha256 = "0p6csrjms3gzcwaxlinsxcdabpr15bsrrp3806vdq2wjc5skd1qk";
    name = "DSM_DS3622xs_plus_86009.pat";
  };

  domainTemplate = ./domains/dsm-vm.xml;

  # Shared prep: writable loader + data disk + staged .pat in the per-VM work dir.
  prep = ''
    name="''${1:-dsm-prod-mirror}"
    work="''${KRG_DSM_RIG_DIR:-$HOME/.local/share/krg-dsm-rig}/$name"
    mkdir -p "$work"
    if [ ! -f "$work/rr.img" ]; then
      unzip -o ${rrLoaderZip} -d "$work"
      chmod u+w "$work/rr.img"
    fi
    [ -f "$work/data.qcow2" ] || qemu-img create -f qcow2 "$work/data.qcow2" 32G
    cp -n ${dsmPat} "$work/DSM_DS3622xs+_86009.pat"
  '';
in
{
  # --- libvirt launcher (managed host) ---
  dsm-vm = pkgs.writeShellApplication {
    name = "dsm-vm";
    runtimeInputs = with pkgs; [ libvirt qemu unzip coreutils gnused ];
    text = ''
      ${prep}
      uri="qemu:///system"
      sed -e "s|@VM_NAME@|$name|g" \
          -e "s|@BOOT_IMG@|$work/rr.img|g" \
          -e "s|@DATA_IMG@|$work/data.qcow2|g" \
          ${domainTemplate} > "$work/$name.xml"
      virsh -c "$uri" define "$work/$name.xml" >/dev/null
      virsh -c "$uri" start "$name"
      echo "Started '$name' (libvirt). console: virsh -c $uri console $name"
      echo "RR menu: DS3622xs+ / DSM 7.3, install from $work/DSM_DS3622xs+_86009.pat"
    '';
  };

  # --- direct-QEMU launcher (portable; no libvirtd, no NixOS module) ---
  dsm-vm-qemu = pkgs.writeShellApplication {
    name = "dsm-vm-qemu";
    runtimeInputs = with pkgs; [ qemu unzip coreutils ];
    text = ''
      ${prep}

      accel=tcg; cpu=max
      if [ -w /dev/kvm ]; then
        accel=kvm; cpu=host
      else
        echo "WARNING: /dev/kvm not writable — falling back to TCG (very slow)."
        echo "  On NixOS, add your user to the kvm group in YOUR config:"
        echo "    users.users.<you>.extraGroups = [ \"kvm\" ];"
      fi

      # SeaBIOS (QEMU default), NOT OVMF/UEFI: RR/redpill loaders page-fault OVMF on
      # the GRUB→kernel handoff (X64 #PF) — they boot in legacy BIOS mode.
      echo "Booting '$name' (accel=$accel, SeaBIOS)."
      echo "  DSM:  http://localhost:5000  (redirects to https://localhost:5001, self-signed cert)"
      echo "  SSH:  ssh -p 2222 ...@localhost   |   VNC: 127.0.0.1:5900   |   RR menu: VNC console"
      echo "  RR install .pat: $work/DSM_DS3622xs+_86009.pat"
      exec qemu-system-x86_64 \
        -name "$name" \
        -machine q35,accel="$accel" \
        -cpu "$cpu" -smp 2 -m 4096 \
        -device ich9-ahci,id=ahci \
        -drive id=loader,file="$work/rr.img",format=raw,if=none \
        -device ide-hd,bus=ahci.0,drive=loader,bootindex=1 \
        -drive id=data,file="$work/data.qcow2",format=qcow2,if=none \
        -device ide-hd,bus=ahci.1,drive=data \
        -netdev user,id=net0,hostfwd=tcp::5000-:5000,hostfwd=tcp::5001-:5001,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -vnc 127.0.0.1:0 \
        -serial mon:stdio
    '';
  };
}
