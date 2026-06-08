# krg.localCache — node-local fast per-user cache at /local/<user>.
#
# WHAT: a plain, durable, NODE-local ZFS dataset (no FUSE, no NFS, no tiering)
# that holds the regenerable, hot, small-file, per-host state that has no business
# sitting on the NFS /home (modules/nfs-home.nix). Two kinds move here:
#   1. IDE remote servers — ~/.vscode-server, ~/.cursor-server — via a SYMLINK
#      created on login (the server tree is per-host and pure cache: delete it and
#      VS Code/Cursor re-download on next connect).
#   2. The cache class — XDG_CACHE_HOME (~/.cache: pip, matplotlib, …), Hugging
#      Face / torch model caches, the conda PACKAGE cache, npm — via per-session
#      env vars pointed under /local/<user>. Only CACHES move; conda ENVS and real
#      data stay in the user's home.
#
# WHY not /home (NFS): the IDE servers and these caches are hot, watch-heavy,
# many-small-file workloads — exactly what NFS is worst at (latency per stat/open,
# and inotify doesn't propagate over NFS so file watchers fall back to polling).
# They're also regenerable, so they don't deserve durable, network-served home
# space. WHY not /scratch (krg.scratch): that namespace DEMOTES cold files onto NFS
# when the pool fills (and reads of demoted files then go over the network) — the
# opposite of what a dev cache wants. This module is the deliberately boring
# counterpart: one local NVMe dataset, fastest path, no network dependency, never
# overflows.
#
# WAITER TOPOLOGY (the only consumer today): nvmepool/local -> /local (legacy mount,
# disko-config.nix). It is OFF the @blank rollback (its own dataset, like
# /var/lib/docker), so caches survive reboots and aren't re-downloaded — and for the
# same reason it needs NO entry in modules/impermanence.nix's /persist bind list.
#
# PER-USER DIR + SYMLINKS: a pam_exec session hook (the same pattern as
# krg.scratch.perUser and pam_mkhomedir) creates /local/<user> (mode 0700) on login,
# then symlinks each `symlinks` name from the user's home into it. GUARDED: only while
# /local is actually mounted (never seed onto a bare mountpoint), and a symlink is
# created ONLY if the home path doesn't already exist — so an existing real
# ~/.vscode-server is never clobbered (such a user opts in once with `rm -rf
# ~/.vscode-server`, then the next login creates the symlink). It ALSO self-heals a
# symlink we manage that has gone dangling (target lost when /local was reprovisioned)
# by recreating just the target — otherwise VS Code/Cursor wedge on a dangling
# ~/.vscode-server. Non-blocking: a failure here never denies login.
#
# CACHE ENV VARS: set via environment.shellInit (cross-shell: bash + zsh), computed
# with `id -un` at shell start (robust where $USER expansion in sessionVariables is
# not), and only exported when /local/<user> exists — so a host/user without this
# cache (or with /local unmounted) just keeps the home defaults.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.localCache;

  # --- per-user dir + symlink creation (pam_exec session hook) ----------------
  # Runs at session open as root (before the session drops to the user). See header
  # for the two guards (mount active; never clobber an existing home path).
  mkPerUserScript = pkgs.writeShellScript "krg-localcache-mkuser" ''
    set -u
    [ -n "''${PAM_USER:-}" ] || exit 0
    mp=${escapeShellArg cfg.mountPoint}
    # Guard 1: only when /local is actually mounted (don't seed a bare mountpoint).
    ${pkgs.util-linux}/bin/mountpoint -q -- "$mp" || exit 0

    d="$mp/$PAM_USER"
    if [ ! -e "$d" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$d" || exit 0
      ${pkgs.coreutils}/bin/chown "$PAM_USER" "$d" || true
      ${pkgs.coreutils}/bin/chmod ${cfg.perUser.mode} "$d" || true
    fi

    # The user's home (NFS) — needed to place the symlinks. If it isn't present
    # (server down), the nfs-home login gate already blocks these users; bail safely.
    home="$(${pkgs.getent}/bin/getent passwd "$PAM_USER" 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 | ${pkgs.coreutils}/bin/cut -d: -f6)"
    [ -n "$home" ] && [ -d "$home" ] || exit 0

    for name in ${concatStringsSep " " (map escapeShellArg cfg.symlinks)}; do
      target="$d/$name"
      link="$home/$name"
      # Guard 2: never clobber an existing real path (-e follows, -L catches a
      # dangling/old symlink). Leave it; the user removes it once to opt in.
      if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$target" || continue
        ${pkgs.coreutils}/bin/chown "$PAM_USER" "$target" || true
        ${pkgs.coreutils}/bin/ln -s "$target" "$link" || continue
        ${pkgs.coreutils}/bin/chown -h "$PAM_USER" "$link" || true
      # Self-heal a dangling managed symlink: the symlink lives in the persistent
      # (NFS) home, but its target is on the node-local dataset — lost whenever /local
      # is reprovisioned/wiped, leaving ~/.vscode-server pointing at nothing. VS Code
      # then dies on `mkdir ~/.vscode-server` ("File exists" + "dangling symlink") and
      # the `if` above can't help (the symlink trips its `! -L`). If `link` is exactly
      # the symlink WE manage (readlink == target) and the target is gone, just
      # recreate the target so it resolves again. The exact-match keeps us from
      # touching a real dir or a symlink the user pointed elsewhere.
      elif [ -L "$link" ] && [ ! -d "$target" ] \
        && [ "$(${pkgs.coreutils}/bin/readlink -- "$link")" = "$target" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$target" || continue
        ${pkgs.coreutils}/bin/chown "$PAM_USER" "$target" || true
      fi
    done
    exit 0
  '';

  # --- cache env vars (environment.shellInit) ---------------------------------
  # Export each cacheEnv var under /local/<user>. `id -un` is set in every shell; this
  # avoids the pam_env $USER-expansion caveat. Tools mkdir their own subdirs on first use.
  # Two guards, both load-bearing:
  #   - `mountpoint -q` (NOT `[ -d ]`): systemd.tmpfiles always creates the bare
  #     <mountPoint> dir, so `[ -d ]` is true even when the dataset FAILED to mount —
  #     which would point caches at the ephemeral root. We require the real mount, the
  #     same check the pam hook uses.
  #   - `[ -d "$__krg_lc" ]`: only redirect if the per-user dir exists. It is created by
  #     the pam hook (running as root, the only one that can write under the 0755
  #     root-owned <mountPoint>); the unprivileged shell can't mkdir it, so without this
  #     the exported XDG_CACHE_HOME etc. would point at a dir the user can't create.
  # mountPoint goes through a shell var (escaped ONCE) so it's never interpolated raw
  # inside a double-quoted bash string (a non-standard mountPoint with $/backticks would
  # otherwise expand).
  shellInitSnippet = optionalString (cfg.cacheEnv != {}) ''
    # krg.localCache: redirect regenerable caches onto node-local NVMe (/local).
    __krg_mp=${escapeShellArg cfg.mountPoint}
    if ${pkgs.util-linux}/bin/mountpoint -q -- "$__krg_mp"; then
      __krg_lc="$__krg_mp/$(${pkgs.coreutils}/bin/id -un 2>/dev/null)"
      if [ -d "$__krg_lc" ]; then
    ${concatStringsSep "\n" (mapAttrsToList (var: rel: "    export ${var}=\"$__krg_lc/${rel}\"") cfg.cacheEnv)}
      fi
      unset __krg_lc
    fi
    unset __krg_mp
  '';
in {
  options.krg.localCache = {
    enable = mkEnableOption "node-local fast per-user cache at /local/<user> (IDE servers + cache class off NFS /home)";

    mountPoint = mkOption {
      type = types.str;
      default = "/local";
      description = "Where the node-local cache dataset mounts; per-user dirs are <mountPoint>/<user>.";
    };

    device = mkOption {
      type = types.str;
      default = "nvmepool/local";
      example = "nvmepool/local";
      description = "ZFS dataset (legacy mountpoint) backing <mountPoint>. Must be OFF the impermanence rollback so caches persist.";
    };

    mountOptions = mkOption {
      type = types.listOf types.str;
      default = ["defaults" "nofail"];
      description = "Mount options for the /local dataset. `nofail` so a missing/late dataset never wedges boot (the pam hook + shellInit both guard on the mount being present).";
    };

    symlinks = mkOption {
      type = types.listOf types.str;
      default = [".vscode-server" ".cursor-server"];
      description = ''
        Home-relative paths symlinked into <mountPoint>/<user> on login (e.g.
        ~/.vscode-server -> /local/<user>/.vscode-server). Created only if the home
        path does not already exist (an existing real dir is never clobbered). A
        symlink we previously created that has gone dangling — its node-local target
        lost to a /local reprovision — is self-healed by recreating the target.
      '';
    };

    cacheEnv = mkOption {
      type = types.attrsOf types.str;
      default = {
        XDG_CACHE_HOME = ".cache"; # pip, matplotlib, many tools
        HF_HOME = ".cache/huggingface"; # Hugging Face hub (hardcodes ~/.cache, ignores XDG)
        TORCH_HOME = ".cache/torch"; # torch.hub model cache
        CONDA_PKGS_DIRS = ".conda/pkgs"; # conda PACKAGE cache (envs stay in home)
        npm_config_cache = ".cache/npm"; # npm download cache
      };
      description = ''
        Cache env vars -> path RELATIVE to <mountPoint>/<user>, exported per shell
        session (only when that dir exists). Only CACHES — never relocate where envs
        or real data live. Set to { } to disable cache redirection (symlinks only).
      '';
    };

    perUser = mkOption {
      default = {};
      description = "On-login creation of the private <mountPoint>/<user> dir (the symlink targets live under it).";
      type = types.submodule {
        options = {
          enable = mkEnableOption "auto-create <mountPoint>/<user> + the symlinks on login";
          mode = mkOption {
            type = types.str;
            default = "0700";
            description = "Mode for each per-user dir (0700 = private to the user).";
          };
          loginServices = mkOption {
            type = types.listOf types.str;
            default = ["sshd" "login"];
            description = "PAM services the per-user/symlink session hook is added to (add `xrdp` if the desktop is enabled).";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # The local dataset is mounted here (disko leaves it mountpoint=legacy with no
      # fileSystems entry, like the scratch datasets, so this module owns the mount).
      fileSystems.${cfg.mountPoint} = {
        inherit (cfg) device;
        fsType = "zfs";
        options = cfg.mountOptions;
      };

      # Bare mountpoint perms before the dataset mounts; once mounted the dataset
      # root (0755 root) shows through, and each user's dir is 0700 (perUser hook).
      systemd.tmpfiles.rules = ["d ${cfg.mountPoint} 0755 root root -"];

      environment.shellInit = shellInitSnippet;
    }

    (mkIf cfg.perUser.enable {
      # Session pam_exec hook on each login service. `optional` so it can NEVER block
      # a login (the cache is not critical). Distinct rule name from krg.scratch's.
      security.pam.services = genAttrs cfg.perUser.loginServices (_: {
        rules.session.krgLocalCacheMkdir = {
          control = "optional";
          modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
          args = ["${mkPerUserScript}"];
          order = 13500; # session open, after pam_mkhomedir and krg.scratch's hook
        };
      });
    })
  ]);
}
