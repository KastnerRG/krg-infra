{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../profiles/compute.nix
    ./hardware-configuration.nix

    # Declarative disk layout (disko) + impermanent ZFS root.
    inputs.disko.nixosModules.disko
    ./disko-config.nix
    ../../modules/impermanence.nix
    ../../modules/nfs-home.nix
    ../../modules/scratch.nix
    ../../modules/local-cache.nix
  ];

  # E4E-owned compute box (E4E-used; the KRG lab generally does not use it), so it
  # takes the e4e-admin break-glass account like e4e-prod — NOT krg-admin. See
  # docs/kastner-ml-onboarding.md.
  krg.adminAccount = "e4e-admin";

  # Physical host — keep the NixOS firewall enabled (base.nix default).
  krg.base.isVM = false;

  # --- userspace deltas from the compute profile (docs/kastner-ml-onboarding.md) ---
  # HEADLESS: nobody uses RDP on this box, and it has no FPGA GUI tools, so drop the
  # XFCE/xrdp desktop the compute profile hard-sets. (allowRDP tracks this, so 3389
  # closes automatically.)
  krg.xrdp.enable = lib.mkForce false;
  # No IPMI/BMC on this workstation-class board (the old ansible left the IPMI
  # exporter commented out), so disable the exporter the compute profile enables.
  krg.ipmiExporter.enable = lib.mkForce false;

  # GPU access: members of the "GPU Users" AD group are bridged into the local `cuda`
  # group (GPU device access). CUDA toolkit + container runtime come from the compute
  # profile's krg.nvidia (nixpkgs cudatoolkit + nvidia-container-toolkit + nix-ld) —
  # same as waiter; the Ubuntu box's apt /usr/local/cuda is deliberately NOT replicated.
  # TODO(AD): "GPU Users" must exist in KRG.LOCAL with members (identity migration).
  krg.nvidia.cudaAccessGroups = ["GPU Users"];

  # Impermanent ZFS root (erase-your-darlings): / rolls back to rpool/root@blank in
  # initrd each boot; durable state is bind-mounted from /persist. The OS pool here is
  # `rpool` (not waiter's `nvmepool`), so point the rollback + import unit at it.
  krg.impermanence.enable = true;
  krg.impermanence.rootSnapshot = "rpool/root@blank";
  krg.impermanence.importUnit = "zfs-import-rpool.service";

  # AD user homes come from NFS — served by e4e-nas, same subnet (132.239.17.0/24) as this
  # box. This moves /home OFF the rolled-back root (the prerequisite for impermanence).
  # requireMountForLogin (default on) fail-closes: if e4e-nas is down at boot, AD logins
  # are denied rather than getting an ephemeral home a reboot would wipe; break-glass
  # e4e-admin (home /var/lib/e4e-admin) is unaffected.
  #
  # Export is the DEDICATED e4e-home share (/volume2/e4e-home, spec/e4e-nas/{shares,
  # nfs-exports}.yml), NOT DSM's "homes" share: it's exported no_root_squash so this box's
  # pam_mkhomedir creates+chowns homes to the SSSD uid — DSM's winbind RID idmap (which
  # doesn't match SSSD's algorithmic range, and can't resolve AD users) is bypassed.
  # Mirrors waiter<->fabricant. nfsVersion pinned to 4.1: Synology DSM tops out at
  # NFSv4.1, so the module default (4.2) is rejected by e4e-nas with "mount.nfs:
  # Protocol not supported" (confirmed on the box 2026-06-17).
  krg.nfsHome = {
    enable = true;
    server = "132.239.17.124"; # e4e-nas.ucsd.edu (pinned by IP — no DNS dependency at mount)
    export = "/volume2/e4e-home";
    nfsVersion = "4.1";
  };

  # AD client (krg.adClient enabled in base.nix). This box is on 132.239.17.0/24 while
  # the DC (krg-ldap) is on 137.110.161.0/24, so pin the DC as ad_server AND as the
  # primary resolver (the module puts serverIp in /etc/hosts + prepends it to
  # nameservers) — otherwise SSSD can't resolve the krg.local SRV records.
  #
  # allowedGroups gates who may SSH in. Locked to Domain Admins for now (fail-safe)
  # until the E4E groups are created in AD. TODO(AD): add the E4E project/lab groups
  # (e.g. "FishSense", "Acoustic Species ID", "Huggingface Users", the CSE237D course
  # group) or an "E4E" umbrella once the ~61 local accounts are migrated to KRG.LOCAL.
  krg.adClient = {
    server = "krg-ldap.krg.local";
    serverIp = "137.110.161.109";
    allowedGroups = ["Domain Admins"];
  };

  # scratchpool holds the group scratch datasets, imported via krg.scratch's fileSystems
  # entries. Listed here too so the pool still imports if a dataset is ever unmounted.
  krg.zfs.extraPools = ["scratchpool"];

  # GROUP-LEVEL /scratch (docs/kastner-ml-onboarding.md): one collaborative,
  # group-owned area per E4E project group — replaces the Ubuntu /share/<project>
  # setgid dirs. perUser is OFF (these are shared group spaces, not per-user); the
  # module applies 3770 (setgid + sticky + group-writable) and chgrps to the AD group,
  # so members collaborate while sticky stops one member deleting another's files.
  #
  # OVERFLOW is OFF for now: the e4e-nas cold-overflow export isn't defined yet, and the
  # 8 TB HDD has ample headroom. When it lands, add `overflow = { enable = true;
  # nfsDevice = "132.239.17.124:/volume1/<scratch-cold>"; coldMountPoint = ...; }` per group.
  #
  # TODO(AD): the ownerGroup AD groups must exist in KRG.LOCAL. Until they resolve, the
  # perms step fails open (area left root-owned/admin-only) and re-tightens on the next run.
  # FOLLOW-UP: shared collaboration needs a group-write umask (002) so member B can edit
  # member A's files — validate on bring-up (the 3770 dir is group-writable, but default
  # umask 022 makes new FILES group-read-only).
  krg.scratch = {
    enable = true;
    projects = {
      fishsense = {
        dataset = "scratchpool/scratch-fishsense";
        ownerGroup = "FishSense";
      };
      aid = {
        dataset = "scratchpool/scratch-aid";
        ownerGroup = "Acoustic Species ID";
      };
      huggingface = {
        dataset = "scratchpool/scratch-huggingface";
        ownerGroup = "Huggingface Users";
      };
    };
  };

  # Node-local per-user cache (krg.localCache): IDE servers + cache class off the NFS
  # /home, on the durable rpool/local dataset (off the @blank rollback). quota 500G is
  # set in disko. NB device override: the OS pool is `rpool`, not the module default
  # nvmepool. HF_HOME is dropped here (see sessionVariables below — it's SHARED, not
  # per-user); localCache keeps managing the other caches per-user.
  krg.localCache = {
    enable = true;
    perUser.enable = true;
    device = "rpool/local";
    cacheEnv = lib.mkForce {
      XDG_CACHE_HOME = ".cache";
      TORCH_HOME = ".cache/torch";
      CONDA_PKGS_DIRS = ".conda/pkgs";
      npm_config_cache = ".cache/npm";
    };
  };

  # SHARED Hugging Face cache (docs/kastner-ml-onboarding.md): point HF_HOME at the
  # group-shared /scratch/huggingface so models download ONCE for all members, instead
  # of waiter's per-user /local HF cache. Set globally; only "Huggingface Users" members
  # can write there (3770), which is the intended audience.
  # FOLLOW-UP: gate this to group members + group-write umask so concurrent member
  # writes work cleanly (same umask caveat as the group scratch above).
  environment.sessionVariables.HF_HOME = "/scratch/huggingface";

  # Swap = zram (no on-disk swap). zstd-compressed RAM cushion for OOM bursts.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # Cap the ZFS ARC at 32 GiB (~25% of 125 GiB) so it can't starve RAM-hungry ML jobs,
  # leaving ~93 GiB for jobs on top of the Optane L2ARC. Tune with arcstat if needed.
  krg.zfs.arcMaxBytes = 32 * 1024 * 1024 * 1024;

  # earlyoom over systemd-oomd (which fights ARC accounting): kill the worst memory hog
  # early before the kernel OOM killer livelocks under ARC + zram pressure.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
  };
  systemd.oomd.enable = false;

  # smartd: scratchpool has NO redundancy (single HDD + single Optane), so advance
  # warning of a failing disk matters. No MTA — escalate via wall + the journal; the
  # zpool-health textfile collector (modules/zfs.nix) covers pool state for Prometheus.
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications.wall.enable = true;
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)"; # short daily 02:00, long weekly Sat 03:00
  };

  networking = {
    hostName = "kastner-ml";
    domain = "ucsd.edu";

    # Static IP on the onboard NIC (verified on-box 2026-06-08: eno1, MAC
    # 9c:5c:8e:bb:74:a7; the second NIC enp11s0 is down/unused).
    useDHCP = false;
    interfaces.eno1.ipv4.addresses = [
      {
        address = "132.239.17.123";
        prefixLength = 24;
      }
    ];
    defaultGateway = "132.239.17.1";
    # krg.adClient prepends the DC (137.110.161.109) as the PRIMARY resolver; these are
    # the site fallbacks (used after the DC), matching the box's old netplan.
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];

    # ZFS requires a unique hostId (load-bearing — see modules/zfs.nix forceImport notes).
    # Generated 2026-06-08; never reuse on another machine.
    hostId = "e37a74ca";
  };

  # Qualys/Trellix enabled for all hosts in base.nix; the installer archive is placed
  # out-of-band at /var/lib/krg/oec/ (credentials never enter the Nix store).

  system.stateVersion = "25.11";
}
