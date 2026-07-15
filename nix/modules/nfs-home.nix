# /home from NFS — give AD users a home that lives OFF the host's local disk.
#
# WHY: SSSD's fallback_homedir=/home/%u + pam_mkhomedir (modules/sssd-ad-client.nix)
# create a home on first login. If /home sits on the local ZFS root, an impermanent
# host (krg.impermanence) would wipe every home on each boot. Mounting /home from NFS
# moves homes off the root, the prerequisite for impermanence. uid/gid are deterministic
# across the fleet (AD algorithmic ID mapping), so a plain sec=sys NFSv4 mount lines up
# without idmapd translation (the client uses numeric ids for AUTH_SYS by default;
# if owners ever show as `nobody`, set the idmapd Domain to krg.local on both ends).
#
# SERVER: fabricant exports this via the ansible nfs_server role (rpool/nfs/home ->
# /srv/nfs/home over NFSv4, no_root_squash so the client's pam_mkhomedir can create
# and chown each user's home).
#
# GOTCHA — local accounts under /home. This mount SHADOWS whatever already sits at
# the mountpoint. The break-glass admin must NOT keep its home here (users/admin.nix
# pins it to /var/lib/<account>), or it would depend on the NFS server being up —
# defeating the point of a break-glass account. (That same off-/home home is also what
# lets the login gate below keep the admin usable when the NFS server is down.)
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.nfsHome;

  # PAM account check (pam_exec): deny login to any user whose home is UNDER the NFS
  # mountpoint when that mount is not active. This stops pam_mkhomedir from creating an
  # ephemeral home on an impermanent root when the server is down — a home the next
  # reboot would erase (silent data loss). Users with homes elsewhere (break-glass admin
  # in /var/lib/<account>) match nothing here, so they log in normally and the host stays
  # recoverable while NFS is down. With the `stdout` pam_exec flag, the message reaches
  # the user being denied.
  homeMountGuard = pkgs.writeShellScript "krg-nfs-home-login-gate" ''
    home="$(${pkgs.getent}/bin/getent passwd "$PAM_USER" 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d: -f6)"
    case "$home" in
      "${cfg.mountPoint}" | "${cfg.mountPoint}/"*)
        if ! ${pkgs.util-linux}/bin/mountpoint -q -- "${cfg.mountPoint}"; then
          echo "Login refused: ${cfg.mountPoint} (network home) is not mounted, so a home created now would be lost on the next reboot. The NFS server may be down — contact an admin."
          exit 1
        fi
        ;;
    esac
    exit 0
  '';
in {
  options.krg.nfsHome = {
    enable = mkEnableOption "mount /home from an NFS server (AD user homes)";

    server = mkOption {
      type = types.str;
      example = "137.110.161.10";
      description = ''
        NFS server address. Prefer the IP for this foundational mount so it doesn't
        depend on DNS at mount time (DNS itself may run on a VM on the very
        hypervisor that serves NFS).
      '';
    };

    export = mkOption {
      type = types.str;
      default = "/srv/nfs/home";
      description = "Server-side export path (fabricant nfs_server serves rpool/nfs/home here).";
    };

    mountPoint = mkOption {
      type = types.str;
      default = "/home";
    };

    nfsVersion = mkOption {
      type = types.str;
      default = "4.2";
    };

    extraOptions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra mount options appended to the defaults.";
    };

    requireMountForLogin = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Gate logins on the NFS home mount being active. A `nofail` mount means the box
        boots even when the server is down (good) — but then pam_mkhomedir would create
        an ephemeral home on the local root for any AD user who logs in, and on an
        impermanent host the next reboot ERASES it (silent data loss). With this on, a
        user whose home is under `mountPoint` is denied login while that mount is down;
        users with homes elsewhere (break-glass admin in /var/lib/<account>) are
        unaffected, so the host stays reachable. Implemented as a PAM account check
        added to `loginServices`.
      '';
    };

    loginServices = mkOption {
      type = types.listOf types.str;
      # xrdp-sesman is the desktop login path (Guacamole→RDP). Include it when the
      # desktop is enabled so the fail-closed "no login while /home is unmounted" gate
      # covers RDP too — otherwise an RDP login while NFS is down slips past the guard
      # and lands the user on an ephemeral home the next reboot wipes.
      default = ["sshd" "login"] ++ optional config.services.xrdp.enable "xrdp-sesman";
      defaultText = literalExpression ''["sshd" "login"] ++ optional config.services.xrdp.enable "xrdp-sesman"'';
      description = "PAM services the login gate (requireMountForLogin) is added to.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      fileSystems.${cfg.mountPoint} = {
        device = "${cfg.server}:${cfg.export}";
        fsType = "nfs";
        # NON-BLOCKING BOOT, the hard way learned (waiter, 2026-05-21). We do NOT use
        # x-systemd.automount here. Autofs at /home looks lazy, but it WEDGES boot: any
        # early-boot service with ProtectHome= (timesyncd, oomd, resolved, …) and
        # systemd-tmpfiles touch /home while building their mount namespaces, which
        # TRIGGERS the autofs mount before the network is up. With `hard` that mount
        # syscall blocks forever and the whole box hangs at "Create System Files and
        # Directories". Do not "optimise" this back to x-systemd.automount.
        #
        # Instead: a plain mount that boot does not wait on.
        #   _netdev                -> ordered After=network-online.target (no pre-net attempt)
        #   nofail                 -> a down/slow server is skipped, never fails/blocks boot
        #   x-systemd.mount-timeout -> bounds the one attempt so a hung server can't stall boot
        #   hard                   -> once mounted, no silent data loss if the server blips
        #   nconnect               -> parallel TCP for throughput
        # If fabricant is down at boot, /home is left unmounted; the login gate
        # (requireMountForLogin) then denies AD logins until it is back, so nobody gets
        # an ephemeral home that a reboot would erase.
        options =
          [
            "nfsvers=${cfg.nfsVersion}"
            "hard"
            "noatime"
            "nconnect=4"
            "_netdev"
            "nofail"
            "x-systemd.mount-timeout=30s"
          ]
          ++ cfg.extraOptions;
      };
    }

    (mkIf cfg.requireMountForLogin {
      security.pam.services = genAttrs cfg.loginServices (_: {
        rules.account.krgNfsHomeGate = {
          control = "required";
          modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
          # `stdout` relays the script's message to the user being denied.
          args = ["stdout" "${homeMountGuard}"];
          # Run late in the account stack (after the user is otherwise validated); a
          # `required` failure denies access regardless of position.
          order = 12000;
        };
      });
    })
  ]);
}
