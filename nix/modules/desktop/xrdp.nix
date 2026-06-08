{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.xrdp;
in {
  imports = [ ../users.nix ];

  options.krg.xrdp = {
    enable = mkEnableOption "XRDP remote desktop with XFCE (waiter compute nodes)";

    # waiter xrdp/sesman.ini values
    maxSessions      = mkOption { type = types.int; default = 50; };
    maxLoginRetry    = mkOption { type = types.int; default = 4; };
    killDisconnected = mkOption { type = types.bool; default = true; };
  };

  config = mkIf cfg.enable {
    services.xrdp = {
      enable               = true;
      defaultWindowManager = "${pkgs.xfce4-session}/bin/xfce4-session";
      # Firewall is managed by krg.firewall (allowRDP = true opens 3389)
      openFirewall         = false;
    };

    services.xserver = {
      enable = true;
      desktopManager.xfce.enable = true;
    };

    environment.systemPackages = with pkgs; [
      xfce4-session
      xfce.xfwm4
      xfce.xfce4-panel
      xfce.xfdesktop       # <--- This handles the wallpaper
      xfce.xfce4-settings  # <--- This provides the menu to change wallpapers
      xfce.xfconf          # <--- The configuration storage system
      firefox
      xhost
    ];

    # RDP access group: created AND assigned only when XRDP is enabled, so it's not
    # a blanket default group (see profiles/compute.nix). The local break-glass admin
    # (a krg.users account) picks it up via defaultGroups; AD users' RDP membership
    # comes from AD. This also means the group always exists when something references it.
    users.groups.rdp_users = {};
    krg.users.defaultGroups = [ "rdp_users" ];
  };
}
