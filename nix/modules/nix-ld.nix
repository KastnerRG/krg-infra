# nix-ld: run dynamically-linked, non-NixOS binaries (no patchelf/FHS needed).
# This is the runtime half of the "/tools" carve-out — closed-source vendor tools
# (Vivado/Vitis, MATLAB, conda envs, etc.) live on the nvmepool/tools dataset and
# are run on the host or bind-mounted into Docker; nix-ld supplies the shared libs
# they expect to dlopen/link at /lib64/ld-linux. The /tools DATASET is declared in
# disko-config.nix; this module is just the loader + library set.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.nixLd;
in {
  options.krg.nixLd = {
    enable = mkEnableOption "nix-ld for running dynamically-linked non-NixOS binaries";

    # Extra libraries appended to the default set below.
    # Useful for conda environments, MATLAB, proprietary research tools, etc.
    extraLibraries = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Additional libraries exposed to nix-ld-managed binaries";
    };
  };

  config = mkIf cfg.enable {
    programs.nix-ld = {
      enable = true;
      libraries = with pkgs;
        [
          # --- C/C++ runtime + core ---
          stdenv.cc.cc.lib # libstdc++, libgcc_s
          glibc
          zlib
          zstd
          xz
          bzip2
          openssl
          curl
          libffi
          ncurses5 # libtinfo.so.5 — older vendor binaries still want it
          readline
          util-linux # libuuid / libblkid / libmount
          libxml2
          sqlite
          glib
          dbus
          expat

          # --- OpenGL / Vulkan / DRM (CUDA-adjacent GUI + compute) ---
          # NOTE: libcuda.so and the GL/Vulkan ICDs come from the NVIDIA driver via
          # /run/opengl-driver (hardware.graphics + krg.nvidia), NOT from this list.
          # These are the surrounding libs such binaries link against.
          libGL
          libGLU
          freeglut
          libdrm
          vulkan-loader

          # --- X11 (Vivado/Vitis/MATLAB pull in a lot of these) ---
          libx11
          libxext
          libxrender
          libxi
          libxrandr
          libxcursor
          libxfixes
          libxt
          libxtst
          libxscrnsaver
          libxcomposite
          libxdamage
          libxcb
          libxft
          libsm
          libice

          # --- Wayland ---
          wayland
          libxkbcommon

          # --- GTK GUI stack (Qt-based tools usually bundle their own Qt) ---
          gtk3
          gdk-pixbuf
          cairo
          pango
          atk
          at-spi2-atk
          at-spi2-core
          harfbuzz

          # --- fonts ---
          fontconfig
          freetype

          # --- audio ---
          alsa-lib
          libpulseaudio

          # --- NSS / NSPR (electron / chromium-based tools) ---
          nss
          nspr

          # --- printing (some GUIs dlopen libcups) ---
          cups
        ]
        ++ cfg.extraLibraries;
    };
  };
}
