# Impermanence ("erase your darlings") for ZFS root.
#
# Every boot, nvmepool/root is rolled back to its empty @blank snapshot (taken at
# install, see disko-config.nix), so `/` starts pristine. Anything that must
# survive a reboot has to be either (a) reproducible from the flake (NixOS
# regenerates it), (b) on a non-rolled-back dataset (/nix, /persist, /tools), or
# (c) listed below to be bind-mounted from /persist into the live root.
#
# GOTCHA — if it isn't reproducible and isn't listed here, IT IS GONE on reboot.
# That's the whole point, but it bites: SSH host keys, machine-id, the AD keytab,
# Docker images, monitoring data, CrowdSec state all live in mutable state and
# would silently reset. The list below is curated for THIS host (server + Docker +
# AD client); add to it when you add stateful services.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib; let
  cfg = config.krg.impermanence;

  # A VALID but empty MIT keytab is just the 2-byte format-version header (0x05 0x02).
  # Used to pre-seed the persisted /etc/krb5.keytab so it isn't a dangling symlink the
  # AD join can't write through. A 0-byte file does NOT work — krb5 rejects it with
  # "Unsupported key table format version number"; it needs this header to append to.
  emptyKeytab = pkgs.runCommand "empty-krb5-keytab" {} ''printf '\005\002' > $out'';
in {
  imports = [inputs.impermanence.nixosModules.impermanence];

  options.krg.impermanence = {
    enable = mkEnableOption "ZFS root rollback to @blank + /persist state";

    persistPath = mkOption {
      type = types.str;
      default = "/persist";
      description = "Durable dataset bind-mounted back into the live root.";
    };

    rootSnapshot = mkOption {
      type = types.str;
      default = "nvmepool/root@blank";
      description = "Snapshot `/` is rolled back to on every boot.";
    };

    importUnit = mkOption {
      type = types.str;
      default = "zfs-import-nvmepool.service";
      description = ''
        Initrd unit that imports the pool holding the root dataset. The rollback is
        ordered After= it and Before= sysroot.mount. NixOS names it
        zfs-import-<poolname>; change this if the root pool isn't nvmepool.
      '';
    };
  };

  config = mkIf cfg.enable {
    # GOTCHA — rollback mechanism choice. We use a systemd-stage-1 service rather
    # than the older scripted `boot.initrd.postDeviceCommands` hook because we need
    # the rollback to run at an EXACT point: after the pool is imported, before the
    # root dataset is mounted. systemd initrd lets us express that with After=/
    # Before=; the scripted hook only gives "after device assembly", which races
    # the mount on some setups. This flips the host to systemd initrd (well
    # supported in 25.11, fine with ZFS); if anything in early boot misbehaves,
    # that's the first knob to check.
    boot.initrd.systemd.enable = true;

    boot.initrd.systemd.services.rollback-root = {
      description = "Roll back ${cfg.rootSnapshot} (impermanence: blank / on boot)";
      wantedBy = ["initrd.target"];
      after = [cfg.importUnit];
      before = ["sysroot.mount"];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      # Match the system's ZFS build (kernel-tied); pulls zfs into the initrd.
      path = [config.boot.zfs.package];
      script = "zfs rollback -r ${cfg.rootSnapshot}";
    };

    # GOTCHA — systemd 258's PID1 hard-checks that /usr is populated and FREEZES if
    # not ("Refusing to run in unsupported environment where /usr/ is not populated").
    # On NixOS /usr/bin/env is the only thing in /usr, and it's created by
    # systemd-tmpfiles — which runs AFTER PID1. So the rolled-back-to-@blank root
    # (empty, see disko-config.nix) has no /usr and PID1 freezes before tmpfiles can
    # fix it: the box hangs at switch-root with that message. (Confirmed on waiter,
    # 2026-05-21 — and it bricks EVERY generation, because the rollback blanks the
    # shared root dataset.) Recreate /usr/bin/env in the rolled-back root here, after
    # it's mounted at /sysroot and before switch-root, so PID1's check passes; stage-2
    # tmpfiles then replaces this with the canonical link. This is what lets @blank
    # stay genuinely EMPTY (true erase-your-darlings) and still boot.
    boot.initrd.systemd.services.populate-usr-bin-env = {
      description = "Seed /usr/bin/env in the rolled-back root (systemd 258 /usr check)";
      wantedBy = ["initrd.target"];
      after = ["sysroot.mount"]; # the rolled-back root is now mounted at /sysroot
      before = ["initrd-switch-root.target"];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      path = [pkgs.coreutils]; # mkdir/ln in the initrd
      # Absolute target resolves post-pivot (/nix is mounted before switch-root); even
      # a dangling link would satisfy the "is /usr non-empty" check, but this one is real.
      script = ''
        mkdir -p /sysroot/usr/bin
        ln -sfn ${pkgs.coreutils}/bin/env /sysroot/usr/bin/env
      '';
    };

    # The persist dataset must be mounted in stage-1, BEFORE the bind mounts that
    # pull state out of it are established — impermanence asserts this. disko's
    # generated fileSystems entry doesn't set it, so merge it in here.
    fileSystems.${cfg.persistPath}.neededForBoot = true;

    # Seed a VALID empty machine keytab at the persist source. /etc/krb5.keytab is
    # persisted as a symlink into /persist, and on a fresh /persist (greenfield rebuild
    # / DR) that target doesn't exist — a DANGLING symlink. The domain-join (adcli/krb5)
    # creates the keytab with open(O_CREAT|O_EXCL), which fails EEXIST on a dangling
    # symlink; and a plain 0-byte file is rejected as "Unsupported key table format
    # version number". So copy a header-only (but valid) keytab into place — `C` copies
    # ONLY if the target is absent, so it never clobbers a populated keytab. /persist/etc
    # already exists (other persisted /etc files).
    systemd.tmpfiles.rules = [
      "C ${cfg.persistPath}/etc/krb5.keytab 0600 root root - ${emptyKeytab}"
    ];

    environment.persistence.${cfg.persistPath} = {
      enable = true;
      hideMounts = true; # keep the bind mounts out of `mount`/df noise

      directories =
        [
          # --- standard server OS state ---
          "/var/log" # FULL /var/log (your call: keep everything for debugging),
          # which includes /var/log/journal — the persistent journal. Needs
          # /etc/machine-id (below) or journald treats each boot as a new host.
          "/var/lib/nixos" # GOTCHA: the uid/gid allocation map. Drop this and
          # dynamically-allocated users/groups get DIFFERENT ids next boot ->
          # wrong file ownership everywhere. Non-negotiable.
          "/var/lib/systemd" # random-seed, timer stamps, coredumps, clock, etc.
          "/root" # root's shell history / state (sudo target; no root SSH).
          "/etc/nixos" # for local/break-glass `nixos-rebuild` (autoUpgrade pulls
          # from GitHub, but keep on-box edits durable).
          # (break-glass admin home /var/lib/<account> is appended after this list,
          # guarded — see below.)

          # --- AD client (krg.adClient, on via base.nix) ---
          "/var/lib/sss" # SSSD cache: offline creds (cache_credentials=true) +
          # machine-account rotation state. Wiped = no offline login + needless
          # re-enumeration each boot. The keytab itself is a file, listed below.

          # --- Docker + compose (compute profile) ---
          # NOTE: /var/lib/docker is intentionally NOT here. It's a dedicated ZFS
          # dataset (nvmepool/docker, see hosts/waiter/disko-config.nix) with its own
          # snapshot policy, so it survives the rollback as a real mount rather than a
          # /persist bind — which also keeps image-layer churn out of /persist's
          # frequent snapshots. A host that enables impermanence WITHOUT such a
          # dataset must add "/var/lib/docker" back here, or Docker state is wiped.
          "/var/lib/krg" # compose-stack working dir: .secrets/ AND Grafana/
          # Prometheus/Loki data + the OEC installer archive. Wiped = monitoring
          # data loss + secrets gone every boot.

          # --- OEC security agents (krg.oecQualysTrellix, on fleet-wide via base) ---
          # The campus-mandated Qualys + Trellix agents install their binaries +
          # enrollment state OUTSIDE /var/lib/krg, onto the rolled-back root. Without
          # these binds a reboot wipes the payload while oec-install's "already
          # installed" marker (now co-located IN /var/lib/fireeye, modules/security/
          # oec-qualys-trellix.nix) shares that fate — so the agents are reinstalled
          # on the next boot if the bind is ever empty. Persisting them keeps a single
          # enrollment across reboots (no per-boot re-enroll churn) and keeps both
          # daemons' ConditionPathExists gates satisfied. Wiped = qualys-cloud-agent +
          # xagt go inactive after the first reboot and the deploy's OEC gate fails.
          "/opt/fireeye" # Trellix xagt binaries + agent_config.json
          "/var/lib/fireeye" # Trellix enrollment db (xagt/main.db) + the install marker
          "/usr/local/qualys" # Qualys Cloud Agent binaries + manifests/correlation
          "/etc/qualys" # Qualys config
          "/var/spool/qualys" # Qualys spool (/var/log/qualys rides /var/log above)

          # NOTE — /local is intentionally NOT here either. krg.localCache mounts it
          # from its own dataset (nvmepool/local, see hosts/waiter/disko-config.nix),
          # off the @blank rollback, so the per-user IDE servers + caches it holds are
          # durable on their own — no /persist bind needed. (Same rationale as
          # /var/lib/docker above.) See modules/local-cache.nix.

          # NOTE — /scratch (krg.scratch, modules/scratch.nix) needs NOTHING here. It's
          # a plain ZFS mount on its own pool (scratchpool, off the @blank rollback), so
          # it's durable on its own; the overflow job keeps its manifest ON that dataset
          # and the archive symlinks are the source of truth — no /persist bind, and no
          # autotier RocksDB to persist anymore (autotier is gone).
        ]
        # Break-glass admin home: users/admin.nix pins it to /var/lib/<account> (OFF
        # /home, so it works when the NFS /home is down) — but that puts it on the
        # rolled-back root, so persist it or it is wiped each boot. Guarded with `?`
        # so this module still evaluates on a host that enables impermanence WITHOUT
        # importing users/admin.nix (which declares krg.adminAccount).
        #
        # STRUCTURED (not a bare string) so impermanence creates the /persist source
        # OWNED BY the admin (0700) instead of root:root. On a FRESH /persist — e.g. a
        # greenfield rebuild / DR — a bare-string entry leaves the bind-source root-owned,
        # so the admin can't write its own home (~/.bash_history etc. fail with EACCES).
        # Group is the account's resolved primary group (NixOS isNormalUser -> "users").
        ++ optional (config.krg ? adminAccount) {
          directory = "/var/lib/${config.krg.adminAccount}";
          user = config.krg.adminAccount;
          group = config.users.users.${config.krg.adminAccount}.group;
          mode = "0700";
        };

      files = [
        "/etc/machine-id" # GOTCHA: stable host identity. Without it, journald +
        # systemd treat every boot as a brand-new machine (new journal namespace,
        # broken log continuity); some services key state off it.

        # SSH host keys — GOTCHA: regenerated every boot otherwise, so every client
        # gets a MITM "REMOTE HOST IDENTIFICATION HAS CHANGED" warning on each
        # reboot. ed25519 is the one base.nix mandates for *clients*; the rsa host
        # key is kept too since sshd still offers it by default.
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"

        # AD machine keytab — GOTCHA: this IS the host's domain membership. Wiped =
        # host drops out of KRG.LOCAL on every boot and SSSD breaks until re-joined.
        # Won't exist until the one-time join/`samba-tool domain exportkeytab`
        # (see docs/creating-a-user.md); persisting the path now is harmless (an
        # empty placeholder) and correct for when the join lands.
        "/etc/krb5.keytab"
      ];
    };
  };
}
