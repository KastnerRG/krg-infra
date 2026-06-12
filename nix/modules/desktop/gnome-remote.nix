# GNOME (Wayland) remote desktop over RDP for the compute nodes — replaces the
# old XRDP+XFCE (X11) module. Uses gnome-remote-desktop's SYSTEM/headless
# "remote login" mode: a system daemon listens on 3389 and hands each connection
# to its own per-user headless GDM session, preserving the multi-user model the
# old xrdp gave us (KDE's KRDP can't — it reuses one shared session). The desktop
# ships an approachable, Windows/KDE-like layout (taskbar + start menu + tray +
# desktop icons) as SOFT, UNLOCKED defaults, so users can override them via the
# GNOME GUI or standalone Home Manager. See docs/remote-desktop.md.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.remoteDesktop;

  # Approachable-desktop extensions, version-matched to nixpkgs' GNOME (so they're
  # tested together — recheck on a GNOME major bump).
  extensions = with pkgs.gnomeExtensions; [
    dash-to-panel # bottom Windows-style taskbar
    arcmenu # Start menu
    appindicator # system tray
    desktop-icons-ng-ding # icons on the desktop
  ];
  extensionUuids = [
    "dash-to-panel@jderose9.github.com"
    "arcmenu@arcmenu.com"
    "appindicatorsupport@rgcjonas.gmail.com"
    "ding@rastersoft.com"
  ];

  gsList = xs: "[${concatMapStringsSep ", " (x: "'${x}'") xs}]";

  grdStateDir = "/var/lib/gnome-remote-desktop";
in {
  imports = [../users.nix];

  options.krg.remoteDesktop = {
    enable = mkEnableOption "GNOME Wayland remote desktop over RDP (gnome-remote-desktop headless remote login)";

    favoriteApps = mkOption {
      type = types.listOf types.str;
      default = [
        "org.gnome.Console.desktop"
        "org.gnome.Nautilus.desktop"
        "firefox.desktop"
      ];
      description = ''
        .desktop IDs pinned to the taskbar by default. A SOFT default — users can
        change their own. Add the FPGA GUI launchers (Vivado/Vitis) once their
        .desktop names on the box are known.
      '';
    };
  };

  config = mkIf cfg.enable {
    # ── Desktop: GNOME on Wayland via GDM ──────────────────────────────────────
    services.xserver.enable = true; # the gdm module needs this even for Wayland
    services.displayManager.gdm.enable = true; # Wayland session by default
    services.desktopManager.gnome.enable = true;

    environment.systemPackages =
      extensions
      ++ [
        pkgs.firefox
        pkgs.gnome-tweaks # so users can tweak their own desktop from the GUI
      ];

    # ── SOFT, UNLOCKED defaults for every user ─────────────────────────────────
    # Shipped as GSettings schema overrides (NOT dconf locks): a familiar STARTING
    # POINT each user can override via the GNOME GUI or standalone Home Manager. On
    # waiter the override lands in the NFS home, so it persists. See
    # docs/remote-desktop.md. (`enabled-extensions`/`favorite-apps` are whole-list
    # keys — a user setting their own replaces ours, which is the intended
    # "their preference wins" behaviour.)
    services.desktopManager.gnome.extraGSettingsOverrides = ''
      [org.gnome.shell]
      enabled-extensions=${gsList extensionUuids}
      favorite-apps=${gsList cfg.favoriteApps}

      [org.gnome.desktop.wm.preferences]
      button-layout=':minimize,maximize,close'

      [org.gnome.desktop.interface]
      color-scheme='prefer-dark'
    '';
    services.desktopManager.gnome.extraGSettingsOverridePackages = [
      pkgs.gnome-shell # org.gnome.shell schema
      pkgs.gsettings-desktop-schemas # org.gnome.desktop.* schemas
    ];

    # ── RDP server: gnome-remote-desktop system/headless "remote login" ────────
    # The NixOS module only exposes `enable`; the TLS cert + `grdctl --system
    # enable` have NO declarative option upstream, so the krg-rdp-bootstrap oneshot
    # below wraps the vendor tool (the same "declarative orchestration of an
    # imperative tool" pattern the synology roles use). State lives under
    # ${grdStateDir}, persisted across the impermanence rollback (below).
    services.gnome.gnome-remote-desktop.enable = true;
    # The packaged systemd unit isn't pulled into the boot transaction by default
    # (known NixOS gap) — wire it to graphical.target.
    systemd.services.gnome-remote-desktop.wantedBy = ["graphical.target"];

    # One-time-ish, self-healing bootstrap: generate a stable self-signed TLS cert
    # if absent, point grd at it, and enable the system RDP service. Idempotent and
    # non-fatal (a failure leaves the local desktop working; RDP just stays off).
    # NEEDS ON-BOX VALIDATION in the maintenance window — the exact grdctl --system
    # invocation/timing is the one thing that can't be verified from a flake eval;
    # docs/remote-desktop.md has the manual fallback.
    systemd.services.krg-rdp-bootstrap = {
      description = "Bootstrap gnome-remote-desktop system RDP (TLS cert + enable)";
      wantedBy = ["graphical.target"];
      before = ["gnome-remote-desktop.service"];
      after = ["systemd-tmpfiles-setup.service"];
      path = [pkgs.gnome-remote-desktop pkgs.openssl];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "gnome-remote-desktop";
        Group = "gnome-remote-desktop";
      };
      script = ''
        set -eu
        cert="${grdStateDir}/tls.crt"
        key="${grdStateDir}/tls.key"
        if [ ! -s "$cert" ] || [ ! -s "$key" ]; then
          openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
            -subj "/CN=${config.networking.hostName}-rdp" \
            -keyout "$key" -out "$cert"
          chmod 600 "$key"
        fi
        grdctl --system rdp set-tls-cert "$cert"
        grdctl --system rdp set-tls-key "$key"
        grdctl --system rdp enable
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${grdStateDir} 0700 gnome-remote-desktop gnome-remote-desktop -"
    ];

    # Persist the cert + enable-state across waiter's @blank rollback (only when
    # impermanence is on; a no-op on durable-root hosts, where the oneshot's
    # self-heal covers it anyway).
    environment.persistence = mkIf config.krg.impermanence.enable {
      ${config.krg.impermanence.persistPath}.directories = [
        {
          directory = grdStateDir;
          user = "gnome-remote-desktop";
          group = "gnome-remote-desktop";
          mode = "0700";
        }
      ];
    };

    # RDP access group: created AND assigned only when the desktop is enabled (same
    # model as the old xrdp module). Break-glass krg-admin picks it up via
    # defaultGroups; AD users' RDP membership comes from AD.
    users.groups.rdp_users = {};
    krg.users.defaultGroups = ["rdp_users"];
  };
}
