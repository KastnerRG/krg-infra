{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.fpga;
  # 1. Create a tiny derivation specifically to provide the libtinfo.so.5 symlink
  vivado-tinfo-shim = pkgs.runCommand "vivado-tinfo-shim" {} ''
    mkdir -p $out/lib
    ln -s ${pkgs.ncurses}/lib/libncursesw.so.6 $out/lib/libtinfo.so.5
  '';
in {
  options.krg.fpga = {
    enable = mkEnableOption "FPGA/EDA development tools (Verilator, GTKWave, Vivado, Questa)";

    enableVerilator = mkOption { type = types.bool; default = true; };
    enableGtkwave   = mkOption { type = types.bool; default = true; };

    # Vivado/Vitis must be installed manually using the Xilinx installer.
    # waiter installs to /tools/Xilinx with versions:
    #   Vivado 2018.2, 2019.1, 2020.2, 2024.1 | Vitis 2022.2 | XRT 2024.1
    vivadoPath = mkOption {
      type    = types.str;
      default = "/tools/Xilinx";
    };

    # waiter vivado.yml: XILINXD_LICENSE_FILE="2100@cselm2.ucsd.edu"
    licenseServer = mkOption {
      type    = types.str;
      default = "2100@cselm2.ucsd.edu";
    };

    # Questa Base (Siemens/Mentor) — used by FlooNoc (floonoc.yaml).
    # Install manually using scripts/install_questa_base_2023.4.sh.
    # waiter installs to: /tools/Siemens/Questa/Base/2023.4
    questaPath = mkOption {
      type    = types.str;
      default = "/tools/Siemens/Questa/Base/2023.4";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs;
      optional cfg.enableVerilator verilator
      ++ optional cfg.enableGtkwave gtkwave
      ++ [
        # System libraries required by Vivado/Vitis/Questa GUI (from waiter vivado.yml + floonoc.yaml)
        zlib
        stdenv.cc.cc.lib
        glib
        gtk3
        xorg.libXrender
        xorg.libX11
        xorg.libXext
        xorg.libXtst
        xorg.libXi
        ncurses5
        libGL
        # Questa-specific dependencies
        freetype
        fontconfig
      ];

    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc
      zlib
      libuuid
      libxcrypt-legacy
      ncurses
      vivado-tinfo-shim  # <-- Injects our custom symlink into the library path

      # X11 / GUI Graphic Libraries
      xorg.libXext 
      xorg.libX11 
      xorg.libXrender 
      xorg.libXtst
      xorg.libXi 
      xorg.libXft 
      xorg.libxcb

      # System fonts and styling
      freetype 
      fontconfig 
      glib 
      gtk2 
      gtk3
    ];
    environment.interactiveShellInit = ''
      # Intercept the 'vivado' command to inject zlib safely for ANY installed version
      vivado() {
        LD_LIBRARY_PATH="${pkgs.zlib}/lib:$LD_LIBRARY_PATH" command vivado "$@"
      }
      vitis() {
        LD_LIBRARY_PATH="${pkgs.zlib}/lib:$LD_LIBRARY_PATH" command vitis "$@"
      }
    '';

    environment.variables = {
      XILINXD_LICENSE_FILE = cfg.licenseServer;
    };

    # Add Vivado, Vitis, and Questa to PATH when installed
    environment.shellInit = ''
      for _v in "${cfg.vivadoPath}"/Vivado/*/; do
        [ -d "$_v/bin" ] && export PATH="$_v/bin:$PATH"
      done
      for _v in "${cfg.vivadoPath}"/Vitis/*/; do
        [ -d "$_v/bin" ] && export PATH="$_v/bin:$PATH"
      done
      if [ -d "${cfg.questaPath}/bin" ]; then
        export PATH="${cfg.questaPath}/bin:$PATH"
      fi
      unset _v
    '';

    systemd.tmpfiles.rules = [
      "d /tools                              0755 root root -"
      "d ${cfg.vivadoPath}                   0755 root root -"
      "d /tools/Siemens                      0755 root root -"
      "d /tools/Siemens/Questa               0755 root root -"
      "d /tools/Siemens/Questa/Base          0755 root root -"
    ];
  };
}
