{
  description = "krg DSM test rig — libvirt/KVM host module, devShell, and DSM-VM launchers. Target: XPEnology DS3622xs+/broadwellnk, DSM 7.3.2-86009, via RR loader 26.4.0. Separate from the production flake at ../nix.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      rig = import ./dsm.nix { inherit pkgs; }; # { dsm-vm, dsm-vm-qemu }
    in {
      # Import into a NixOS config to provision the libvirt host (for the dsm-vm path).
      nixosModules.libvirt-host = import ./modules/libvirt-host.nix;

      # `nix develop ./test` — everything to drive the rig + the IaC under test, pinned.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          libvirt # virsh
          qemu_kvm
          opentofu # IaC layer is OpenTofu (ADR 0005)
          ansible
          yq-go
          jq
          garage # garage CLI (garage_config role)
          python3 # drift_exporter dev + the synology API client (pip/poetry, not a nixpkgs pkg)
          nix-prefetch # recompute sha256 when bumping the RR .img / DSM .pat pins
        ];
        shellHook = ''
          echo "krg DSM test rig — virsh / tofu / ansible / yq / garage pinned."
          echo "Portable (no libvirtd):  nix run ./test#dsm-vm-qemu [name]"
          echo "Via libvirt (managed):   nix run ./test#dsm-vm [name]"
        '';
      };

      packages.${system} = { inherit (rig) dsm-vm dsm-vm-qemu; };

      apps.${system} = {
        # libvirt path — needs the krg.dsmRig host module (qemu:///system).
        dsm-vm = {
          type = "app";
          program = "${rig.dsm-vm}/bin/dsm-vm";
        };
        # portable path — direct QEMU, no libvirtd / no NixOS module; only needs /dev/kvm.
        dsm-vm-qemu = {
          type = "app";
          program = "${rig.dsm-vm-qemu}/bin/dsm-vm-qemu";
        };
      };
    };
}
