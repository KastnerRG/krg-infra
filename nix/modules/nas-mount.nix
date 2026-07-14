# Constrained per-user CIFS mounts of the E4E NAS.
#
# PROBLEM: mounting a CIFS share needs root, but non-admin AD users have no sudo.
# Handing them raw `sudo mount` (even wildcarded in sudoers) can't constrain the
# mountpoint to their home or block hostile `-o` options — a user could mount a
# share over /etc. In a breach-driven hardening repo that's an unacceptable
# escalation surface.
#
# SOLUTION: a tiny root wrapper (`e4e-nas-mount`) granted NOPASSWD to one AD group.
# The wrapper is the security boundary — it enforces, in code, that:
#   * the source is //<server>/<share> and nothing else (server is fixed here),
#   * <share> is a bare share name (no slashes / traversal),
#   * the mountpoint canonicalizes to a path UNDER the caller's home.
# It maps ownership to the caller (uid/gid/cruid) so the mounted files are theirs,
# and mounts nosuid,nodev. Membership in `allowedGroup` (sudoers) is the access gate.
#
# AUTH IS KERBEROS (sec=krb5), NOT a password/cred file — no secret on disk. The
# mount authenticates as the CALLER via their Kerberos ticket: `cruid=<caller-uid>`
# tells cifs.upcall whose credential cache to use (the cifs.spnego upcall is already
# wired on the compute profile — profiles/compute.nix).
#
# FEELS AUTOMATIC: the wrapper obtains the ticket itself. If the caller has no valid
# TGT it runs `kinit` AS THE CALLER, prompting once for their AD password (key-only
# SSH can't auto-issue a TGT, so a single password entry is unavoidable without
# storing a per-user secret); an existing ticket is reused with no prompt. After
# that, the per-user `krg-krenew` service (`perUserRenew`, on by default) keeps the
# renewable ticket alive in the background for the whole session — up to the
# krb5.conf renew_lifetime (7d) — so a VALID TICKET never lapses. All of this works
# because the ccache is a deterministic per-uid FILE (sssd-ad-client.nix
# default_ccache_name), shared by kinit, krenew, and the cifs.upcall reconnect path.
#
# THIS DOES NOT FULLY COVER a dropped SMB session, though. If the connection to the
# NAS actually drops (network blip, NAS-side idle timeout), the kernel's keyutils
# request-key facility can end up serving a NEGATIVELY CACHED result for the cifs
# session's key — so the next access fails immediately with ENOKEY ("Required key
# not available") WITHOUT re-invoking cifs.upcall at all, even though the user's TGT
# is perfectly valid (observed on kastner-ml: `ls <mountpoint>` failed with "Host is
# down" then "Required key not available", while `klist` showed a valid ticket, and
# `journalctl -k -t cifs.upcall` showed repeated kernel SessSetup=-126 errors with NO
# corresponding upcall invocations — i.e. the kernel wasn't even asking Kerberos
# again). krenew can't fix this: it only renews the ticket, not the wedged session.
# A full unmount+remount forces a fresh key request and clears it.
#
# AUTO-RECONNECT (`autoReconnect`, on by default): the wrapper records each
# successful mount (target + share) to /run/e4e-nas-mounts/<uid>.list (root-owned,
# world-readable — only mount paths/share names, not sensitive) and forgets it again
# on unmount. A per-user `krg-nas-mount-healthcheck` timer periodically stats each
# still-mounted entry; if the stat hangs/errors (the wedge symptom above), it
# self-heals by calling back into this SAME wrapper (`-u` then a fresh mount) via the
# user's existing NOPASSWD sudo grant — no new privilege needed.
#
# UX:  sudo e4e-nas-mount <share> [mountpoint]   # prompts for AD password iff no ticket
#      sudo e4e-nas-mount -u <mountpoint>
# e.g. sudo e4e-nas-mount passive-acoustic-biodiversity tests
#      -> mounts //e4e-nas.ucsd.edu/passive-acoustic-biodiversity at ~/tests,
#         authenticated as the caller via their ticket, owned by the caller.
#
# User + operator runbook: docs/e4e-nas-mount.md.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.nasMount;

  mountTool = pkgs.writeShellApplication {
    name = "e4e-nas-mount";
    # cifs-utils is multi-output — mount.cifs lives in the `bin` output, not the
    # default `out` (lib only). See modules/nix-multi-output note / compute.nix.
    runtimeInputs = [
      pkgs.util-linux # mount, umount, runuser, findmnt
      pkgs.cifs-utils.bin # mount.cifs helper
      pkgs.coreutils # id, cut, realpath, mkdir, printf
      pkgs.krb5 # klist (ticket presence check)
      pkgs.getent
      pkgs.gnugrep
    ];
    text = ''
      server=${escapeShellArg cfg.server}
      smbver=${escapeShellArg cfg.smbVersion}

      # Mount-tracking state for the auto-reconnect health-check (autoReconnect).
      # World-readable by design: only mount paths + share names land here (not
      # sensitive), and the per-user health-check timer reads its own uid's file as
      # an unprivileged user, not root. `install -d` (not `mkdir -p -m`, which only
      # applies -m to the deepest component) sets the mode unconditionally.
      install -d -m 0755 /run/e4e-nas-mounts

      usage() {
        echo "usage: sudo e4e-nas-mount <share> [mountpoint]" >&2
        echo "       sudo e4e-nas-mount -u <mountpoint>" >&2
        echo "" >&2
        echo "  Mounts //$server/<share> under your home directory, authenticated" >&2
        echo "  as you via your Kerberos ticket. Run 'kinit' first if you have none." >&2
        echo "  mountpoint defaults to ~/<share>." >&2
        exit 2
      }

      if [ "$(id -u)" -ne 0 ]; then
        echo "e4e-nas-mount: must be run with sudo" >&2
        exit 1
      fi
      # Must be invoked via sudo by a real user (sudo sets SUDO_UID/SUDO_GID/SUDO_USER
      # itself, so these are trustworthy — not attacker-supplied env).
      : "''${SUDO_UID:?run this via sudo, not as root directly}"
      : "''${SUDO_GID:?run this via sudo, not as root directly}"
      : "''${SUDO_USER:?run this via sudo, not as root directly}"

      state="/run/e4e-nas-mounts/$SUDO_UID.list"

      # Drop any existing line for $target from the state file (used both when
      # forgetting an unmounted target and before re-recording a remount). Silent
      # no-op if the file doesn't exist yet or $target isn't present (set -e-safe:
      # grep -v returns 1 when nothing remains, which isn't an error here).
      forget_target() {
        { grep -vF "$target " "$state" 2>/dev/null || true; } >"$state.tmp"
        mv -f "$state.tmp" "$state"
      }

      caller_home="$(getent passwd "$SUDO_UID" | cut -d: -f6)"
      if [ -z "$caller_home" ] || [ ! -d "$caller_home" ]; then
        echo "e4e-nas-mount: cannot resolve your home directory" >&2
        exit 1
      fi
      home="$(realpath -e -- "$caller_home")"

      # ---- unmount mode ----
      if [ "''${1:-}" = "-u" ] || [ "''${1:-}" = "--unmount" ]; then
        [ "$#" -eq 2 ] || usage
        mp="$2"
        case "$mp" in /*) ;; *) mp="$home/$mp" ;; esac
        target="$(realpath -m -- "$mp")"
        case "$target/" in "$home"/*) ;; *) echo "refuses: mountpoint not under your home" >&2; exit 1 ;; esac
        if ! findmnt -no FSTYPE --target "$target" | grep -q '^cifs$'; then
          echo "e4e-nas-mount: $target is not a cifs mount" >&2
          exit 1
        fi
        umount -- "$target"
        forget_target
        echo "unmounted $target"
        exit 0
      fi

      # ---- mount mode ----
      { [ "$#" -ge 1 ] && [ "$#" -le 3 ]; } || usage
      share="$1"
      # Bare share name only — no slashes, no traversal, restricted charset.
      case "$share" in
        "" | */* | *..*) echo "refuses: invalid share name '$share'" >&2; exit 1 ;;
      esac
      if ! printf '%s' "$share" | grep -qE '^[A-Za-z0-9._-]+$'; then
        echo "refuses: share name may only contain [A-Za-z0-9._-]" >&2
        exit 1
      fi

      mp="''${2:-$share}"
      case "$mp" in /*) ;; *) mp="$home/$mp" ;; esac
      # realpath -m canonicalizes symlinks in existing components + normalizes '..',
      # so a ~/foo symlink pointing at /etc is caught by the under-home check below.
      target="$(realpath -m -- "$mp")"
      if [ "$target" = "$home" ]; then
        echo "refuses: will not mount over your home directory itself" >&2
        exit 1
      fi
      case "$target/" in
        "$home"/*) ;;
        *) echo "refuses: mountpoint must be under your home ($home)" >&2; exit 1 ;;
      esac

      # Create the mountpoint AS the caller so ownership + permission semantics are
      # theirs (runuser can't create where the user themselves couldn't).
      if [ ! -e "$target" ]; then
        runuser -u "$SUDO_USER" -- mkdir -p -- "$target"
      fi
      if [ ! -d "$target" ]; then
        echo "e4e-nas-mount: mountpoint $target is not a directory" >&2
        exit 1
      fi

      # Ensure the caller has a live ticket, obtaining one on demand so the mount
      # "just works" from a single command. kinit is run AS THE CALLER (runuser) so
      # the TGT lands in THEIR uid-pinned ccache (FILE:/tmp/krb5cc_<uid>) — the same
      # cache cifs.upcall reads — not root's. It prompts for the AD password only when
      # there's no valid ticket; an existing (e.g. still-renewed) ticket is reused
      # silently. renew_lifetime in krb5.conf makes this a renewable TGT, which the
      # per-user krg-krenew service then keeps alive for long-lived mounts.
      if ! runuser -u "$SUDO_USER" -- klist -s; then
        echo "e4e-nas-mount: no valid Kerberos ticket — authenticating you to the domain" >&2
        if ! runuser -u "$SUDO_USER" -- kinit; then
          echo "e4e-nas-mount: kinit failed — cannot mount without a ticket" >&2
          exit 1
        fi
      fi

      # Residual TOCTOU (accepted, mirrors scratch-restore): a component of $target
      # swapped to a symlink between this check and the mount could redirect it. Full
      # fix = per-component openat traversal; disproportionate here (attacker is the
      # caller, files map to their own uid). We mount the CANONICAL path to shrink it.
      #
      # sec=krb5 + cruid=<caller>: cifs.upcall reads the CALLER's credential cache to
      # get the service ticket — no password/secret on disk. uid/gid map file ownership
      # to the caller so the mount is theirs.
      #
      # Not `exec`: the auto-reconnect health-check needs this mount recorded to
      # $state AFTER a successful mount, so the process must return here rather than
      # being replaced by mount(8).
      if mount -t cifs "//$server/$share" "$target" \
        -o "sec=krb5,cruid=$SUDO_UID,uid=$SUDO_UID,gid=$SUDO_GID,vers=$smbver,file_mode=0700,dir_mode=0700,nosuid,nodev"; then
        forget_target
        printf '%s %s\n' "$target" "$share" >>"$state"
        chmod 0644 "$state"
      else
        exit 1
      fi
    '';
  };

  # Runs per-user (unprivileged) via the krg-nas-mount-healthcheck timer. Detects a
  # wedged cifs session (see the module-header comment on negatively-cached kernel
  # keys after a dropped SMB connection) and self-heals by calling back into the
  # wrapper via the user's own NOPASSWD sudo grant — no new privilege needed.
  healthCheckTool = pkgs.writeShellApplication {
    name = "e4e-nas-mount-healthcheck";
    runtimeInputs = [pkgs.util-linux pkgs.coreutils];
    text = ''
      uid="$(id -u)"
      state="/run/e4e-nas-mounts/$uid.list"
      [ -f "$state" ] || exit 0

      while IFS=' ' read -r mp share; do
        [ -n "''${mp:-}" ] || continue

        # Not mounted anymore (the user ran -u themselves, or a reboot cleared
        # /run) — nothing to heal. The wrapper already forgets on -u; this only
        # catches an entry orphaned some other way.
        if ! findmnt -no FSTYPE --target "$mp" 2>/dev/null | grep -q '^cifs$'; then
          continue
        fi

        # A healthy mount answers a bounded stat immediately. The wedge this
        # guards against (stale negatively-cached kernel key after an SMB session
        # drop) makes every access fail fast with ENOKEY/EHOSTDOWN — either way,
        # the timeout below catches it.
        if timeout 5 ls -- "$mp" >/dev/null 2>&1; then
          continue
        fi

        echo "e4e-nas-mount-healthcheck: $mp ($share) looks wedged — reconnecting" >&2
        # /run/wrappers/bin/sudo: the setuid NixOS sudo wrapper, not a nix store
        # path — same reasoning as the sudoers `command` entry below (a store path
        # here would fail the same way once security.wrappers regenerates it).
        /run/wrappers/bin/sudo /run/current-system/sw/bin/e4e-nas-mount -u "$mp" || true
        /run/wrappers/bin/sudo /run/current-system/sw/bin/e4e-nas-mount "$share" "$mp" || true
      done <"$state"
    '';
  };
in {
  options.krg.nasMount = {
    enable = mkEnableOption "constrained per-user CIFS mounts of the E4E NAS via a sudo wrapper gated on an AD group";

    server = mkOption {
      type = types.str;
      default = "e4e-nas.ucsd.edu";
      description = "The ONLY SMB server the wrapper will mount from (hard-coded into the wrapper — a user cannot point it elsewhere).";
    };

    allowedGroup = mkOption {
      type = types.str;
      default = "E4E-NAS";
      example = "E4E-NAS";
      description = ''
        AD group (space-free) granted NOPASSWD sudo to the mount wrapper. This is the
        access gate. Must exist in KRG.LOCAL (spec/krg-ad/groups.yml).
      '';
    };

    smbVersion = mkOption {
      type = types.str;
      default = "3.1.1";
      description = "SMB protocol version passed as `vers=` to mount.cifs.";
    };

    perUserRenew = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run a per-user `systemd --user` service (`krg-krenew`) that keeps each logged-in
        user's Kerberos TGT renewed for the session (via krenew), so a krb5 mount stays
        reconnectable past the 10h ticket lifetime without the user re-authenticating.
        The wrapper obtains the initial ticket (kinit) on demand; this keeps it alive.
      '';
    };

    autoReconnect = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run a per-user `systemd --user` timer (`krg-nas-mount-healthcheck`) that
        periodically checks each mount the wrapper made this session and, if it's
        wedged (a stale negatively-cached kernel key after the SMB session actually
        drops — see the module header comment; `perUserRenew`/krenew alone does NOT
        cover this), transparently unmounts and remounts it via the same wrapper.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [mountTool];

    # allowedGroup is space-free by contract, so security.sudo.extraRules (which does
    # NOT escape spaces) is safe here. A bare command path allows any arguments — the
    # wrapper itself validates them.
    #
    # Command is the STABLE /run/current-system/sw/bin path, NOT the Nix store path
    # (${mountTool}/bin/e4e-nas-mount): sudo matches the `command` field as a literal
    # string against the invoked path, it does not resolve symlinks to compare
    # underlying files. Users run the bare `sudo e4e-nas-mount ...` (docs/e4e-nas-mount.md),
    # which $PATH resolves to the environment.systemPackages profile symlink at
    # /run/current-system/sw/bin/ — not the store path — so granting the store path here
    # left every user permanently denied regardless of group membership (observed on
    # kastner-ml: `sudo -l` showed the store path granted, but the runtime denial quoted
    # /run/current-system/sw/bin/e4e-nas-mount as the disallowed command).
    security.sudo.extraRules = [
      {
        groups = [cfg.allowedGroup];
        commands = [
          {
            command = "/run/current-system/sw/bin/e4e-nas-mount";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    # Keep the session's TGT renewed in the background. krenew latches onto the ticket
    # the wrapper's kinit created (both use the uid-pinned FILE ccache) and rolls fresh
    # 10h tickets up to renew_lifetime (7d) — so the user kinit's at most once per
    # session and long mounts never drop. Runs per-user under the logind user manager,
    # so it starts on login and stops at logout (renewal tracks being logged in).
    systemd.user.services.krg-krenew = mkIf cfg.perUserRenew {
      description = "Renew the user's Kerberos TGT for the session (e4e-nas mounts)";
      wantedBy = ["default.target"];
      serviceConfig = {
        Type = "simple";
        # -K 60: wake every 60s, renew when the ticket is within 60 min of expiry.
        # Exits non-zero when no ticket exists yet (before the first kinit) or once the
        # renewable lifetime is exhausted; Restart then re-latches when a ticket appears.
        ExecStart = "${pkgs.kstart}/bin/krenew -K 60";
        Restart = "always";
        RestartSec = 300;
      };
    };

    # Auto-reconnect a wedged mount (see module header: a dropped SMB session can
    # leave a negatively-cached kernel key that krenew's ticket renewal can't clear).
    # Runs per-user, same lifecycle as krg-krenew (starts at login, stops at logout).
    systemd.user.services.krg-nas-mount-healthcheck = mkIf cfg.autoReconnect {
      description = "Detect and reconnect a wedged e4e-nas cifs mount";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${healthCheckTool}/bin/e4e-nas-mount-healthcheck";
      };
    };
    systemd.user.timers.krg-nas-mount-healthcheck = mkIf cfg.autoReconnect {
      description = "Periodic health-check for e4e-nas cifs mounts";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "3min";
      };
    };
  };
}
