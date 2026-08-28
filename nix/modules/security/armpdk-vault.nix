# krg.armpdkVault — read-only VeraCrypt mount of the export-controlled ARM PDK.
#
# CONTEXT (ARM Technology Control Plan / export control). The ARM PDK is licensed,
# export-controlled IP: it must live encrypted at rest and be readable only by the
# authorized users named on the ARM agreement + TCP. This module implements the
# *storage* half of that plan on waiter (the CSE access server); the *access* half
# (RDP forced through an auditable SSH tunnel, key-only SSH) is modules/desktop/
# xrdp.nix `krg.xrdp.gatewayDeny` + ssh hardening. See docs/arm-pdk-veracrypt.md for
# the TCP-paragraph → implementation mapping.
#
# SHAPE (chosen with the operator, 2026-06-18):
#   * The encrypted container (a VeraCrypt volume, AES + SHA-512) is the SINGLE
#     canonical copy on fabricant, served READ-ONLY over NFS (rpool/nfs/armpdk ->
#     /srv/nfs/armpdk, ansible nfs_server). waiter mounts that export read-only and
#     veracrypt-mounts the .hc file from it read-only. If fabricant drops, the mount
#     falls off — accepted (the PDK is reference data, not a boot dependency).
#   * The passphrase is NEVER on the box. Per the TCP it lives in the admin-only
#     VaultWarden; an administrator supplies it interactively at mount time. So this
#     module does NOT auto-mount with an on-box key and does NOT use vault-agent —
#     it gives admins a wrapper (`armpdk-mount`, prompts on the tty) and an optional
#     `systemd-ask-password` unit. "Mounted read-only by system administrators on
#     system boot and remains mounted" = an admin runs one of these after each boot.
#   * Access segregation is by Linux group: the AD group "ARM PDK Access" is bridged
#     to a fixed-GID local group (krg.adGroupSync) so the mountpoint — and the
#     volume's own root dir, see the runbook — gate on it. The volume's internal
#     ownership/perms are baked at CREATION (a read-only mount can't chown), so the
#     runbook sets root:armpdk 0750 on the volume root before populating it.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with lib; let
  cfg = config.krg.armpdkVault;
  nfsMountUnit = "${utils.escapeSystemdPath cfg.nfsMountPoint}.mount";

  # The CLI flags shared by mount paths: read-only, no keyfiles/PIM/hidden-volume
  # protection, text mode. We deliberately DON'T pass --non-interactive: veracrypt
  # then prompts for the passphrase on the controlling terminal (admin pastes it from
  # VaultWarden), and these flags suppress the OTHER prompts so only the password is
  # asked. `--fs-options=ro` is belt-and-suspenders alongside --read-only.
  mountFlags = concatStringsSep " " [
    "--text"
    "--mount"
    "--read-only"
    "--fs-options=ro"
    "--pim=0"
    "--keyfiles="
    "--protect-hidden=no"
  ];

  veracrypt = "${pkgs.veracrypt}/bin/veracrypt";

  # Interactive admin wrapper: prompts on the tty (passphrase pasted from VaultWarden,
  # never written to disk). Requires root — veracrypt sets up a device-mapper target.
  mountScript = pkgs.writeShellApplication {
    name = "armpdk-mount";
    runtimeInputs = [pkgs.veracrypt pkgs.util-linux pkgs.coreutils];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "armpdk-mount: must run as root (veracrypt sets up a device-mapper target)." >&2
        exit 1
      fi
      container=${escapeShellArg cfg.containerFile}
      mountpoint=${escapeShellArg cfg.mountPoint}
      if mountpoint -q -- "$mountpoint"; then
        echo "armpdk-mount: $mountpoint is already mounted — nothing to do."
        exit 0
      fi
      if [ ! -e "$container" ]; then
        echo "armpdk-mount: container $container not present. Is the fabricant NFS export (${cfg.server}:${cfg.export}) mounted at ${cfg.nfsMountPoint}?" >&2
        exit 1
      fi
      echo "armpdk-mount: mounting the ARM PDK read-only at $mountpoint."
      echo "Enter the VeraCrypt passphrase from VaultWarden (admin-only)."
      exec ${veracrypt} ${mountFlags} "$container" "$mountpoint"
    '';
  };

  dismountScript = pkgs.writeShellApplication {
    name = "armpdk-dismount";
    runtimeInputs = [pkgs.veracrypt pkgs.util-linux];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "armpdk-dismount: must run as root." >&2
        exit 1
      fi
      mountpoint=${escapeShellArg cfg.mountPoint}
      if ! mountpoint -q -- "$mountpoint"; then
        echo "armpdk-dismount: $mountpoint is not mounted — nothing to do."
        exit 0
      fi
      exec ${veracrypt} --text --dismount "$mountpoint"
    '';
  };
in {
  imports = [../ad-group-sync.nix];

  options.krg.armpdkVault = {
    enable = mkEnableOption "read-only VeraCrypt mount of the export-controlled ARM PDK";

    server = mkOption {
      type = types.str;
      default = "137.110.161.98";
      description = ''
        NFS server (fabricant) holding the single canonical VeraCrypt container.
        Pinned by IP — like krg.nfsHome/krg.scratch — so the mount doesn't depend on
        DNS, which itself runs on a VM on this hypervisor.
      '';
    };

    export = mkOption {
      type = types.str;
      default = "/srv/nfs/armpdk";
      description = "Server-side export path (fabricant nfs_server serves rpool/nfs/armpdk here, read-only).";
    };

    nfsMountPoint = mkOption {
      type = types.str;
      default = "/srv/armpdk-src";
      description = "Where the fabricant NFS export is mounted (holds the .hc container, read-only).";
    };

    containerFile = mkOption {
      type = types.str;
      default = "${cfg.nfsMountPoint}/armpdk.hc";
      defaultText = literalExpression ''"''${nfsMountPoint}/armpdk.hc"'';
      description = "Path to the VeraCrypt container file (under the NFS mount).";
    };

    mountPoint = mkOption {
      type = types.str;
      default = "/opt/arm-pdk";
      description = "Where the decrypted volume is mounted (read-only).";
    };

    accessGroups = mkOption {
      type = types.listOf types.str;
      default = ["ARM PDK Access"];
      description = ''
        AD groups whose members may read the PDK. Bridged into the fixed-GID local
        group `localGroup` via krg.adGroupSync (pam/space-safe), which gates the
        mountpoint. MUST match the volume's internal group ownership (set at creation
        — see the runbook), since a read-only mount can't be re-chowned.
      '';
    };

    localGroup = mkOption {
      type = types.str;
      default = "armpdk";
      description = "Fixed-GID local group the access AD group(s) are bridged into.";
    };

    gid = mkOption {
      type = types.int;
      default = 65010;
      description = ''
        Fixed GID for localGroup. Must be the SAME GID used for group ownership inside
        the container when it's created on fabricant (NFS sec=sys carries numeric ids),
        or the segregated access won't line up. 65010 is unused on the fleet (cuda is
        65533); keep it stable.
      '';
    };

    askPasswordUnit = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Also provide an `armpdk-vault.service` an admin starts with
        `systemctl start armpdk-vault`: it prompts for the passphrase via
        systemd-ask-password (answerable over SSH with
        `systemd-tty-ask-password-agent`) and mounts read-only, ExecStop dismounts.
        NOT auto-started (no wantedBy) — there is no on-box key, by design.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [pkgs.veracrypt mountScript dismountScript];

    # FUSE — VeraCrypt's userspace mount path uses it.
    boot.kernelModules = ["fuse"];

    # Fixed-GID local group; AD "ARM PDK Access" members bridged in by adGroupSync.
    users.groups.${cfg.localGroup}.gid = cfg.gid;
    # localGroup defaults to the attribute name (= cfg.localGroup), so it's implicit.
    krg.adGroupSync.${cfg.localGroup}.adGroups = cfg.accessGroups;

    # The fabricant NFS export, mounted READ-ONLY. Same non-blocking-boot recipe as
    # krg.nfsHome (plain nofail mount, NOT x-systemd.automount — autofs wedges early
    # boot): a down server is skipped, never blocks/fails boot, and the volume simply
    # can't be mounted until it's back (accepted — "falling off is fine").
    fileSystems.${cfg.nfsMountPoint} = {
      device = "${cfg.server}:${cfg.export}";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "ro"
        "hard"
        "noatime"
        "_netdev"
        "nofail"
        "x-systemd.mount-timeout=30s"
      ];
    };

    # Pre-mount mountpoint: root:armpdk 0750 so the empty dir is group-gated when
    # nothing is mounted. Once the volume is mounted its OWN root dir perms apply
    # (the mount shadows this), which is why the runbook bakes root:armpdk 0750 into
    # the volume at creation.
    systemd.tmpfiles.rules = [
      "d ${cfg.mountPoint} 0750 root ${cfg.localGroup} -"
    ];

    systemd.services.armpdk-vault = mkIf cfg.askPasswordUnit {
      description = "ARM PDK — read-only VeraCrypt mount (admin-initiated, passphrase via systemd-ask-password)";
      # Deliberately NOT wantedBy any target: there is no on-box key, so this only
      # runs when an admin starts it. Order after the NFS source mount so the
      # container is present.
      after = [nfsMountUnit "network-online.target"];
      wants = ["network-online.target"];
      requires = [nfsMountUnit];
      unitConfig.RequiresMountsFor = [cfg.nfsMountPoint];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # systemd-ask-password prompts the admin (console, or over SSH via
        # `systemd-tty-ask-password-agent`); the answer is piped straight into
        # veracrypt --stdin and never touches disk.
        ExecStart = pkgs.writeShellScript "armpdk-vault-start" ''
          set -euo pipefail
          if ${pkgs.util-linux}/bin/mountpoint -q -- ${escapeShellArg cfg.mountPoint}; then
            echo "armpdk-vault: already mounted."
            exit 0
          fi
          ${pkgs.systemd}/bin/systemd-ask-password --no-tty "ARM PDK VeraCrypt passphrase (from VaultWarden):" \
            | ${veracrypt} ${mountFlags} --stdin ${escapeShellArg cfg.containerFile} ${escapeShellArg cfg.mountPoint}
        '';
        ExecStop = "${dismountScript}/bin/armpdk-dismount";
      };
    };
  };
}
