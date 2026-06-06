# krg.scratch — per-lab /scratch on a plain ZFS dataset, with automatic NFS overflow.
#
# WHAT: each lab (project) gets ONE /scratch/<lab> directory that is a plain ZFS
# mount (NOT a FUSE layer). On waiter that dataset lives on `scratchpool` — striped
# HDD for capacity, fronted by an NVMe metadata (special) vdev + NVMe L2ARC, so ZFS
# serves hot reads from RAM/NVMe and keeps the bytes on the (large) HDD. There is no
# tiering daemon in the read path; the kernel ZFS ARC/L2ARC handles hot/cold.
#
# WHY NOT autotier (the previous design): autotier was a 45Drives FUSE filesystem
# that moved files NVMe->HDD->NFS by access frequency. It wrote a RocksDB record on
# every file open/close and ABORTED under concurrent small-file training reads (a
# multi-worker dataloader), taking /scratch down with it. It is unmaintained (last
# release Dec 2021) and unfixable by config. See docs/scratch-greenfield.md and the
# disko-config.nix "WHY THIS LAYOUT" block. The whole FUSE failure class is gone now.
#
# CAPACITY OVERFLOW (the only mover, and it's OUT of the read hot path): when the
# pool fills past a high-water mark, the per-lab `overflow` job (scratch-overflow,
# a daily systemd timer) demotes the least-recently-accessed files to a cold NFS
# area on fabricant and replaces each with a SYMLINK to the NFS copy — so the path
# still works (reads just go over the network) and `scratch-restore` pulls a file
# back to fast storage on demand. It is FAIL-CLOSED: a local file is unlinked only
# after its NFS copy is fully written, fsynced, and verified (size + sha256); if the
# cold mount is down the unit won't even start (RequiresMountsFor). This is the
# automatic, recoverable, no-policing capacity backstop the design calls for.
#
# LAB ISOLATION (krg and e4e are INDEPENDENT labs sharing this box): each lab's
# /scratch tree is chmod 3770 (setgid + sticky), group = that lab's AD group (krg -> "Kastner Research
# Group"), so one lab can't read another's data on shared hardware. Because this is
# a plain ZFS mount (no FUSE create-impersonation quirk), it's a real 3770 — no o+x
# hack is needed (that was an autotier-only workaround). With `perUser.enable`, each
# lab member also gets a private <mountPoint>/<user> auto-created on login (a
# pam_exec session hook), guarded on the mount being active (fail-closed, same as
# the modules/nfs-home.nix /home gate).
#
# IMPERMANENCE: the scratch dataset is on its own pool (scratchpool, off
# nvmepool/root), so it survives the boot rollback untouched. The overflow job keeps
# its manifest ON the scratch dataset (durable, travels with the data) and the
# symlinks themselves are the source of truth for restore — nothing here needs a
# /persist bind.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
with lib; let
  cfg = config.krg.scratch;

  # Hardened NFS options for the cold overflow area — identical posture to
  # modules/nfs-home.nix: _netdev+nofail so a down server never blocks boot, hard so
  # no silent loss once mounted, nconnect for throughput, bounded mount-timeout so a
  # hung server can't stall. The overflow unit's RequiresMountsFor makes "cold down"
  # fail closed (the mover refuses to run rather than leaving files unarchived-but-
  # -counted, or worse, deleting locals it couldn't copy).
  nfsColdOptions = [
    "nfsvers=4.2"
    "hard"
    "noatime"
    "nconnect=4"
    "_netdev"
    "nofail"
    "x-systemd.mount-timeout=30s"
  ];

  # perUser.homeLink must be a SINGLE path segment: non-empty, no "/" (so its parent
  # is always $HOME — the hook never has to mkdir a root-owned dir in the user's home),
  # and not "." / "..". Validated at eval time.
  badHomeLink = p: p == "" || hasInfix "/" p || p == "." || p == "..";

  # mountPoint/coldMountPoint are rendered raw into tmpfiles rules, RequiresMountsFor,
  # fileSystems keys and the perms script — none of which tolerate whitespace. Reject
  # it at eval time rather than try to escape every site (the ExecStart argv is escaped
  # separately). Paths with whitespace are painful across ZFS/systemd anyway.
  hasWhitespace = s: any (c: hasInfix c s) [" " "\t" "\n"];

  # scratch-overflow / scratch-restore as stdlib-only Python. writePython3Bin gives a
  # build-time syntax + import check; flakeIgnore drops style-only lints (line length
  # etc.) — the scripts are the real source of truth in nix/modules/scratch/*.py.
  pyArgs = {
    libraries = [];
    flakeIgnore = ["E501" "E226" "W503" "W504"];
  };
  scratchOverflow =
    pkgs.writers.writePython3Bin "scratch-overflow" pyArgs
    (builtins.readFile ./scratch/scratch-overflow.py);
  scratchRestore =
    pkgs.writers.writePython3Bin "scratch-restore" pyArgs
    (builtins.readFile ./scratch/scratch-restore.py);

  # --- ownership / isolation step (a post-mount oneshot) ----------------------
  # Runs AFTER the mount is active (RequiresMountsFor) and after sssd, so the AD lab
  # group resolves. chmod 3770 the scratch root; chgrp to the lab group only if it
  # resolves — TOLERANT so /scratch still comes up (root-owned, admin-only) before
  # the AD join / group creation lands, then tightens on the next start. The group
  # name has spaces ("Kastner Research Group"), so it's quoted.
  #
  # 3770 = setgid (new entries inherit the lab group) + STICKY. The sticky bit is what
  # makes per-user isolation hold at the root: the tree is group-writable so members
  # can create their own per-user dir, but sticky means a member can only rename/delete
  # entries they OWN — they can't blow away another user's /scratch/<user> tree.
  mkPermsScript = name: proj:
    pkgs.writeShellScript "krg-scratch-perms-${name}" ''
      set -u
      mp=${escapeShellArg proj.mountPoint}
      # chgrp FIRST, chmod LAST: chgrp can clear the setgid bit, so applying 3770 after
      # it guarantees the final mode (incl. setgid+sticky) regardless.
      ${optionalString (proj.ownerGroup != null) ''
        if ${pkgs.getent}/bin/getent group ${escapeShellArg proj.ownerGroup} >/dev/null 2>&1; then
          ${pkgs.coreutils}/bin/chgrp ${escapeShellArg proj.ownerGroup} "$mp" || \
            echo "krg.scratch[${name}]: chgrp failed on $mp" >&2
        else
          echo "krg.scratch[${name}]: group ${escapeShellArg proj.ownerGroup} not resolvable yet (AD join/group pending?) — $mp left root-owned (admin-only), will apply on next start" >&2
        fi
      ''}
      ${pkgs.coreutils}/bin/chmod 3770 "$mp" || \
        echo "krg.scratch[${name}]: chmod 3770 $mp failed" >&2
      exit 0
    '';

  # --- per-user dir creation (pam_exec session hook) --------------------------
  # Runs at session open, as root. Creates <mountPoint>/<PAM_USER> for lab members,
  # and (if perUser.homeLink is set) a convenience symlink ~/<homeLink> -> that dir.
  # GUARDED two ways: (1) only if the scratch mount is active — never create on the
  # bare/ephemeral root when the dataset isn't mounted; (2) only for members of
  # ownerGroup, compared by NUMERIC gid since the group name may contain spaces.
  # Does NOT early-exit when the per-user dir already exists, so a RETURNING user
  # still gets the home symlink (re)laid. The symlink is never created over an
  # existing REAL path (a real ~/<homeLink> is left untouched); the home is NFS
  # (no_root_squash) so root can create it + chown it to the user.
  mkPerUserScript = name: proj:
    pkgs.writeShellScript "krg-scratch-mkuser-${name}" ''
      set -u
      [ -n "''${PAM_USER:-}" ] || exit 0
      mp=${escapeShellArg proj.mountPoint}
      ${pkgs.util-linux}/bin/mountpoint -q -- "$mp" || exit 0
      ${optionalString (proj.ownerGroup != null) ''
        gid=$(${pkgs.getent}/bin/getent group ${escapeShellArg proj.ownerGroup} | ${pkgs.coreutils}/bin/cut -d: -f3)
        [ -n "$gid" ] || exit 0
        case " $(${pkgs.coreutils}/bin/id -G "$PAM_USER" 2>/dev/null) " in
          *" $gid "*) : ;;
          *) exit 0 ;;
        esac
      ''}
      d="$mp/$PAM_USER"
      if [ ! -e "$d" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$d" || exit 0
        ${pkgs.coreutils}/bin/chown "$PAM_USER" "$d" || true
        ${optionalString (proj.ownerGroup != null) ''
        # group = the lab group (gid resolved above) so a 2770 mode actually shares
        # within the lab; chgrp BEFORE chmod so the setgid bit isn't stripped.
        ${pkgs.coreutils}/bin/chgrp "$gid" "$d" || true
      ''}
        ${pkgs.coreutils}/bin/chmod ${proj.perUser.mode} "$d" || true
      fi
      ${optionalString (proj.perUser.homeLink != null) ''
        # homeLink is a SINGLE path segment (asserted), so the link's parent is $home
        # itself — we never mkdir (and so never leave a root-owned dir in the home).
        home=$(${pkgs.getent}/bin/getent passwd "$PAM_USER" | ${pkgs.coreutils}/bin/cut -d: -f6)
        if [ -n "$home" ] && [ -d "$home" ]; then
          link="$home/${proj.perUser.homeLink}"
          # leave a real (non-symlink) path alone; otherwise create/refresh the symlink
          if [ -e "$link" ] && [ ! -L "$link" ]; then
            :
          else
            ${pkgs.coreutils}/bin/ln -sfn "$d" "$link" || true
            ${pkgs.coreutils}/bin/chown -h "$PAM_USER" "$link" || true
          fi
        fi
      ''}
      exit 0
    '';

  overflowType = types.submodule {
    options = {
      enable = mkEnableOption "automatic cold-file overflow to NFS for this lab";
      pool = mkOption {
        type = types.str;
        default = "";
        description = "ZFS pool whose capacity drives overflow. Empty = derive from the dataset's pool.";
      };
      nfsDevice = mkOption {
        type = types.str;
        example = "137.110.161.98:/srv/nfs/scratch-krg";
        description = "NFS export (server:/path) used as the cold overflow area.";
      };
      coldMountPoint = mkOption {
        type = types.str;
        example = "/srv/scratch-cold/krg";
        description = "Where the cold NFS export is mounted (symlink targets land here).";
      };
      highWatermark = mkOption {
        type = types.ints.between 1 100;
        default = 85;
        description = "Start demoting cold files when the pool is at least this %% full.";
      };
      lowWatermark = mkOption {
        type = types.ints.between 1 100;
        default = 75;
        description = "Stop demoting once the pool drops below this %% full.";
      };
      minAgeDays = mkOption {
        type = types.ints.unsigned;
        default = 14;
        description = "Capacity-sweep floor: never demote a file accessed within this many days (keep the working set local).";
      };
      maxIdleDays = mkOption {
        type = types.ints.unsigned;
        default = 0;
        example = 180;
        description = ''
          TTL sweep: demote ANY file not ACCESSED in this many days, regardless of pool
          fullness — the automatic GC for genuinely-abandoned data (runs every sweep,
          not just when full). Keyed on last-access (relatime), so an actively-read file
          is never evicted. 0 = disabled (capacity sweep only). Must exceed minAgeDays.
        '';
      };
      interval = mkOption {
        type = types.str;
        default = "daily";
        description = "systemd OnCalendar for the overflow sweep.";
      };
      mountOptions = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra mount options appended to the hardened NFS defaults for the cold area.";
      };
    };
  };

  projectType = types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      mountPoint = mkOption {
        type = types.str;
        default = "/scratch/${name}";
        description = "Where this lab's scratch dataset mounts (what users see).";
      };
      dataset = mkOption {
        type = types.str;
        example = "scratchpool/scratch-krg";
        description = "The ZFS dataset (mountpoint=legacy in disko) mounted at mountPoint.";
      };
      ownerGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Kastner Research Group";
        description = ''
          Lab group that owns this scratch tree (mode 3770, setgid+sticky) so other labs are
          denied. An AD/SSSD group (may contain spaces). null = leave root-owned
          (admin-only). When set, the perms step orders after sssd so it resolves.
        '';
      };
      perUser = mkOption {
        default = {};
        description = ''
          Auto-create a private per-user directory <mountPoint>/<user> on login — a
          pam_exec session hook, the scratch analogue of pam_mkhomedir. Created only
          for members of `ownerGroup`, and only while the scratch mount is active.
          Non-blocking: a failure here never denies login.
        '';
        type = types.submodule {
          options = {
            enable = mkEnableOption "per-user directories under this lab's scratch";
            mode = mkOption {
              type = types.str;
              default = "0700";
              description = "Mode for each per-user dir. 0700 = private; 2770 = shared within the lab.";
            };
            loginServices = mkOption {
              type = types.listOf types.str;
              default = ["sshd" "login"];
              description = "PAM services the per-user-dir session hook is added to.";
            };
            homeLink = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "scratch";
              description = ''
                If set, lay a convenience symlink <user-home>/<homeLink> ->
                <mountPoint>/<user> on login (e.g. "scratch" → ~/scratch). Requires
                `enable`. The link lives in the (NFS) home so it appears on every host
                that mounts that home, while the target is THIS box's local scratch —
                so on a host that mounts the home but lacks this scratch path it would
                dangle. NEVER created over an existing real path (a real ~/<homeLink>
                is left untouched); an existing symlink is refreshed to the right
                target. Must be a SINGLE path segment (no "/") so the link sits
                directly in $HOME — the hook then never creates (root-owned) parent
                dirs in the user's home.
              '';
            };
          };
        };
      };
      overflow = mkOption {
        type = overflowType;
        default = {};
        description = "Automatic cold-file overflow to NFS (see scratch-overflow / scratch-restore).";
      };
    };
  });
in {
  options.krg.scratch = {
    enable = mkEnableOption "per-lab /scratch on plain ZFS with automatic NFS overflow";

    projects = mkOption {
      type = types.attrsOf projectType;
      default = {};
      description = "Per-lab scratch instances, keyed by lab name.";
      example = literalExpression ''
        {
          krg = {
            dataset = "scratchpool/scratch-krg";
            ownerGroup = "Kastner Research Group";
            perUser.enable = true;
            overflow = {
              enable = true;
              nfsDevice = "137.110.161.98:/srv/nfs/scratch-krg";
              coldMountPoint = "/srv/scratch-cold/krg";
            };
          };
        }
      '';
    };
  };

  config = mkIf (cfg.enable && cfg.projects != {}) (
    let
      projectList = mapAttrsToList (name: proj: {inherit name proj;}) cfg.projects;
      anyOverflow = any ({proj, ...}: proj.overflow.enable) projectList;
      # the pool driving overflow for a project (overflow.pool override, else the
      # dataset's own pool)
      ovPool = proj:
        if proj.overflow.pool != ""
        then proj.overflow.pool
        else head (splitString "/" proj.dataset);
    in {
      assertions = concatLists (mapAttrsToList (name: proj: [
          {
            assertion = proj.dataset != "";
            message = "krg.scratch.projects.${name}: dataset must be set.";
          }
          {
            assertion =
              !proj.overflow.enable
              || proj.overflow.lowWatermark < proj.overflow.highWatermark;
            message = "krg.scratch.projects.${name}: overflow.lowWatermark must be < highWatermark.";
          }
          {
            assertion =
              !proj.overflow.enable
              || (proj.overflow.nfsDevice != "" && proj.overflow.coldMountPoint != "");
            message = "krg.scratch.projects.${name}: overflow needs nfsDevice and coldMountPoint.";
          }
          {
            # TTL must sit beyond the capacity floor, else the two windows overlap nonsensically.
            assertion =
              proj.overflow.maxIdleDays
              == 0
              || proj.overflow.maxIdleDays > proj.overflow.minAgeDays;
            message = "krg.scratch.projects.${name}: overflow.maxIdleDays must exceed minAgeDays (or be 0 to disable).";
          }
          {
            # homeLink only fires from the per-user hook, so it no-ops without perUser.enable.
            assertion = proj.perUser.homeLink == null || proj.perUser.enable;
            message = "krg.scratch.projects.${name}: perUser.homeLink requires perUser.enable.";
          }
          {
            # The per-user hook gates creation on ownerGroup membership; without an
            # ownerGroup it would create dirs for every user, contradicting the isolation
            # model the option documents. Require a group when perUser is on.
            assertion = !proj.perUser.enable || proj.ownerGroup != null;
            message = "krg.scratch.projects.${name}: perUser.enable requires ownerGroup (per-user dirs are gated on lab-group membership).";
          }
          {
            # The link is laid under $HOME; reject anything that could escape it.
            assertion = proj.perUser.homeLink == null || !(badHomeLink proj.perUser.homeLink);
            message = "krg.scratch.projects.${name}: perUser.homeLink must be a single path segment under $HOME (no \"/\", not \".\"/\"..\").";
          }
          {
            # rendered raw into tmpfiles/RequiresMountsFor/fileSystems/perms — no whitespace.
            assertion = !(hasWhitespace proj.mountPoint);
            message = "krg.scratch.projects.${name}: mountPoint must not contain whitespace.";
          }
          {
            assertion = !proj.overflow.enable || !(hasWhitespace proj.overflow.coldMountPoint);
            message = "krg.scratch.projects.${name}: overflow.coldMountPoint must not contain whitespace.";
          }
        ])
        cfg.projects);

      # scratch-restore (self-service) + scratch-overflow (admin --dry-run) on PATH,
      # only when some lab uses overflow.
      environment.systemPackages = optionals anyOverflow [scratchRestore scratchOverflow];

      # Tell scratch-restore which cold areas are legitimate, so it refuses to follow
      # or delete a symlink target outside them (a lab member could plant a malicious
      # symlink under /scratch and trick a root restore into unlinking an arbitrary
      # file). Colon-separated, mirrors each overflow lab's coldMountPoint.
      environment.variables = mkIf anyOverflow {
        SCRATCH_COLD_ROOTS =
          concatStringsSep ":"
          (map ({proj, ...}: proj.overflow.coldMountPoint)
            (filter ({proj, ...}: proj.overflow.enable) projectList));
        # scratch mountpoints — restore uses this to keep the link itself inside a
        # scratch tree (a symlinked dir component can't redirect a root restore out).
        SCRATCH_ROOTS =
          concatStringsSep ":"
          (map ({proj, ...}: proj.mountPoint) projectList);
        # scratch->cold pairing ("scratchMP=coldMP;..."): restore pins a link's target
        # to its CANONICAL archive location (cold + relpath(link, scratch)), so a
        # planted symlink to some OTHER cold file can't get that file unlinked.
        SCRATCH_OVERFLOW_MAP =
          concatStringsSep ";"
          (map ({proj, ...}: "${proj.mountPoint}=${proj.overflow.coldMountPoint}")
            (filter ({proj, ...}: proj.overflow.enable) projectList));
      };

      # The scratch dataset mount (plain ZFS, nofail so a hiccup never blocks boot)
      # plus, per overflow-enabled lab, the cold NFS area (hardened posture).
      fileSystems = mkMerge (concatMap (
          {
            name,
            proj,
          }:
            [
              {
                ${proj.mountPoint} = {
                  device = proj.dataset;
                  fsType = "zfs";
                  options = ["defaults" "nofail"];
                };
              }
            ]
            ++ optional proj.overflow.enable {
              ${proj.overflow.coldMountPoint} = {
                device = proj.overflow.nfsDevice;
                fsType = "nfs";
                options = nfsColdOptions ++ proj.overflow.mountOptions;
              };
            }
        )
        projectList);

      # /scratch parent + each lab mountpoint must exist before the mounts. 0755 is
      # the bare mountpoint; the perms step tightens the mounted root to 3770. NOTE:
      # systemd-tmpfiles-resetup re-applies these `d` rules to the *mounted* root on
      # every `nixos-rebuild switch`, reverting that 3770 — so krg-scratch-perms-* is
      # bound to re-fire after resetup (see systemd.services below).
      # /scratch + each lab mountpoint, plus each overflow lab's cold mountpoint (and
      # its parent) so the NFS mount target exists at boot with admin-only perms. The
      # NFS mount overlays it; the local dir only shows through when NFS is down (and
      # then overflow is fail-closed anyway). `unique` dedupes a shared parent.
      systemd.tmpfiles.rules = unique (
        ["d /scratch 0755 root root -"]
        ++ map ({
          name,
          proj,
        }: "d ${proj.mountPoint} 0755 root root -")
        projectList
        ++ concatMap ({
          name,
          proj,
        }:
          optionals proj.overflow.enable [
            "d ${dirOf proj.overflow.coldMountPoint} 0755 root root -"
            "d ${proj.overflow.coldMountPoint} 0700 root root -"
          ])
        projectList
      );

      systemd.services = listToAttrs (concatMap (
          {
            name,
            proj,
          }:
          # ---- ownership/isolation: chmod 3770 + chgrp lab group, after the mount ----
          # MUST re-run on every activation, not just at boot: a `nixos-rebuild switch`
          # restarts systemd-tmpfiles-resetup.service, whose `systemd-tmpfiles --create`
          # re-applies the `d ${mountPoint} 0755 root root` rule to the *mounted* dataset
          # root — silently reverting this 3770+lab-group hardening to world-traversable
          # 0755 root:root until the next reboot (lab isolation off in the meantime).
          # `after` orders this oneshot AFTER that resetup clobber; `partOf` propagates
          # resetup's activation restart to here, so it re-fires and re-tightens the
          # mode/group every switch. mkPermsScript is idempotent, so re-running is safe.
            [
              (nameValuePair "krg-scratch-perms-${name}" {
                description = "Set ownership/mode on ${proj.mountPoint} (lab isolation)";
                wantedBy = ["multi-user.target"];
                after =
                  ["systemd-tmpfiles-resetup.service"]
                  ++ optional (proj.ownerGroup != null) "sssd.service";
                wants = optional (proj.ownerGroup != null) "sssd.service";
                partOf = ["systemd-tmpfiles-resetup.service"];
                unitConfig.RequiresMountsFor = [proj.mountPoint];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = mkPermsScript name proj;
                };
              })
            ]
            # ---- capacity overflow: demote cold files to NFS (fail-closed) ----
            ++ optional proj.overflow.enable
            (nameValuePair "scratch-overflow-${name}" {
              description = "Demote cold ${proj.mountPoint} files to NFS (${ovPool proj} capacity)";
              # RequiresMountsFor pulls in + orders after BOTH the scratch mount and the
              # cold NFS area, so a down cold tier keeps this from starting (fail closed)
              # rather than deleting locals it can't archive.
              unitConfig.RequiresMountsFor = [proj.mountPoint proj.overflow.coldMountPoint];
              path = [config.boot.zfs.package pkgs.coreutils];
              serviceConfig = {
                Type = "oneshot";
                # argv list + escapeSystemdExecArgs so any special characters in the args
                # are handled safely by systemd's parser. (Whitespace in mountPoint/
                # coldMountPoint is separately rejected at eval time by assertions above.)
                ExecStart = utils.escapeSystemdExecArgs ([
                    "${scratchOverflow}/bin/scratch-overflow"
                    "--pool"
                    (ovPool proj)
                    "--scratch"
                    proj.mountPoint
                    "--cold"
                    proj.overflow.coldMountPoint
                    "--high"
                    (toString proj.overflow.highWatermark)
                    "--low"
                    (toString proj.overflow.lowWatermark)
                    "--min-age-days"
                    (toString proj.overflow.minAgeDays)
                  ]
                  ++ optionals (proj.overflow.maxIdleDays > 0)
                  ["--max-idle-days" (toString proj.overflow.maxIdleDays)]);
                # bound resource use of the daily sweep
                Nice = 10;
                IOSchedulingClass = "idle";
              };
            })
        )
        projectList);

      systemd.timers = listToAttrs (concatMap (
          {
            name,
            proj,
          }:
            optional proj.overflow.enable
            (nameValuePair "scratch-overflow-${name}" {
              description = "Periodic cold-file overflow sweep for ${proj.mountPoint}";
              wantedBy = ["timers.target"];
              timerConfig = {
                OnCalendar = proj.overflow.interval;
                Persistent = true;
                RandomizedDelaySec = "10m";
              };
            })
        )
        projectList);

      # Per-user dir auto-creation: a session pam_exec hook on the configured login
      # services, for each lab that opts into perUser. `optional` so it can never
      # block a login. Different rule name per lab so multiple labs don't collide.
      security.pam.services = mkMerge (concatMap (
          {
            name,
            proj,
          }:
            optionals proj.perUser.enable (map (svc: {
                ${svc}.rules.session."krgScratchMkdir_${name}" = {
                  control = "optional";
                  modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
                  args = ["${mkPerUserScript name proj}"];
                  order = 13000; # session open, after pam_mkhomedir
                };
              })
              proj.perUser.loginServices)
        )
        projectList);
    }
  );
}
