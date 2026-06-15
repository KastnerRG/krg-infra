{
  inputs,
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

  # Physical host — keep the NixOS firewall enabled (this is the default).
  krg.base.isVM = false;

  # Impermanent ZFS root (erase-your-darlings): / is rolled back to nvmepool/root@blank
  # in initrd every boot; durable state is bind-mounted back from /persist
  # (modules/impermanence.nix). Enabling this also flips the host to systemd initrd
  # (the rollback runs as a stage-1 unit). VALIDATED on-box across two reboots 2026-05-21.
  #
  # Two fixes had to land before this was safe (both now in tree):
  #  - /home is on NFS and the mount is NON-BLOCKING (krg.nfsHome below — plain nofail,
  #    NOT x-systemd.automount, which wedged early boot). This moves user homes OFF the
  #    rolled-back root so they aren't wiped each boot.
  #  - the rolled-back root is empty, and systemd 258's PID1 FREEZES on an empty /usr
  #    ("Refusing to run ... /usr/ is not populated"); modules/impermanence.nix reseeds
  #    /usr/bin/env in initrd before switch-root so it boots (see that module + the
  #    disko-config.nix @blank note).
  #
  # GOTCHA when (re)enabling on a running or freshly-installed host: migrate live state
  # into /persist BEFORE the first rollback (keytab, ssh host keys, /etc/machine-id,
  # /var/lib/{nixos,sss,krg}; break-glass admin home /var/lib/<account> is in the list),
  # or the first boot wipes it. Deploy with `nixos-rebuild boot` (NOT switch — switch
  # fails on persist-files "file already exists"). /nix, /persist, /tools and
  # /var/lib/docker are separate datasets, off the rolled-back root.
  krg.impermanence.enable = true;

  # AD user homes come from NFS (fabricant: rpool/nfs/home -> /srv/nfs/home). This
  # moves /home OFF waiter's local ZFS root — the prerequisite for impermanence above.
  # Break-glass krg-admin is unaffected: its home is /var/lib/krg-admin (users/admin.nix),
  # which impermanence persists (modules/impermanence.nix). Server pinned by IP so /home
  # never waits on DNS. The mount is a PLAIN nofail NFS mount (NOT an automount — autofs
  # wedged early boot; see modules/nfs-home.nix), ordered after the network: the box
  # always boots, and if fabricant is down at boot /home is simply left UNMOUNTED (it
  # does NOT mount on later access — a remount or reboot is needed once the server is back).
  #
  # KNOWN TRADE-OFF (impermanence + nofail /home): if /home is unmounted at login time,
  # pam_mkhomedir (krg.adClient) creates an ephemeral home on the rolled-back root that
  # is WIPED on the next reboot — a data-loss window absent from the old persistent root.
  # fabricant being down at boot is already a major incident (it also hosts the AD DC, so
  # only SSSD-cached logins would even succeed), but gating AD logins on the /home mount
  # to close that window is a tracked follow-up (see CLAUDE.md pending items).
  krg.nfsHome = {
    enable = true;
    server = "137.110.161.98"; # fabricant (the hypervisor serving rpool/nfs)
  };

  # scratchpool (HDD data + NVMe special/cache) holds the /scratch dataset, imported
  # via krg.scratch's fileSystems entry for /scratch/krg. List it explicitly too so
  # the (unmounted) e4e scaffolding dataset's pool still imports at boot. (nvmepool is
  # imported because / lives on it.) The old hddpool is gone — its disks are now the
  # scratchpool data vdev (see disko-config.nix).
  krg.zfs.extraPools = ["scratchpool"];

  # /scratch for the krg lab — PLAIN ZFS now (modules/scratch.nix), not autotier/FUSE.
  # /scratch/krg is scratchpool/scratch-krg: bytes on the striped HDD, hot reads served
  # by the NVMe special (metadata) vdev + L2ARC. ZFS does the hot/cold caching in-kernel,
  # so the autotier FUSE daemon — which crashed under concurrent training reads — is gone.
  # See docs/scratch-greenfield.md and the disko-config.nix "WHY THIS LAYOUT" block.
  #
  # LAB ISOLATION: krg and e4e are INDEPENDENT labs sharing this box, so /scratch/krg is
  # owned by the "Kastner Research Group" AD group, mode 3770 (setgid+sticky — a real
  # ZFS-mount mode now; the old autotier o+x hack is gone; sticky stops a member
  # deleting another member's per-user dir). The "Kastner Research Group" group already
  # exists in Samba AD (it backed the prior deploy), so the perms step applies 3770
  # as soon as SSSD resolves it after the domain re-join; it stays tolerant
  # (/scratch/krg root-owned/admin-only) if the group can't yet resolve, so /scratch
  # always comes up — then tightens on the next start.
  #
  # E4E IS NOT WIRED: no e4e users/machines yet, so scratchpool/scratch-e4e stays
  # mountpoint=none (disko) reserved scaffolding. e4e will later get e4e-nas as its NFS
  # overflow target (separate work). Add a `projects.e4e` here then.
  #
  # OVERFLOW (capacity backstop, NOT in the read path): fabricant exports
  # rpool/nfs/scratch-krg with no_root_squash (ansible nfs_server), mounted here at
  # /srv/scratch-cold/krg. When scratchpool fills past the high-water mark, the daily
  # scratch-overflow timer demotes the least-recently-accessed files there and leaves a
  # symlink (reads still work over NFS); `scratch-restore` pulls a file back. FAIL-CLOSED:
  # if the cold mount is down the unit won't start (RequiresMountsFor) and a local file is
  # never unlinked until its NFS copy is verified. Plenty of headroom today (~29 TiB), so
  # this rarely fires — it's the automatic, recoverable, no-policing backstop for later.
  krg.scratch = {
    enable = true;
    projects.krg = {
      dataset = "scratchpool/scratch-krg";
      ownerGroup = "Kastner Research Group";
      # Each krg lab member gets a private /scratch/krg/<user>, auto-created on login
      # (only for Kastner-Research-Group members, only while /scratch/krg is mounted),
      # plus a convenience symlink ~/scratch -> /scratch/krg/<user> so people don't have
      # to memorize the path. The link lives in the NFS home (so it'd appear on any host
      # mounting that home) but the target is waiter-local scratch; today only waiter
      # mounts /home so it resolves. A real ~/scratch is never clobbered.
      perUser.enable = true;
      perUser.homeLink = "scratch";
      overflow = {
        enable = true;
        # fabricant hypervisor IP, same server as krg.nfsHome — pinned by IP so it
        # never waits on DNS.
        nfsDevice = "137.110.161.98:/srv/nfs/scratch-krg";
        coldMountPoint = "/srv/scratch-cold/krg";
        # TTL: drain anything not touched in 6 months to NFS even when the pool isn't
        # full — automatic GC of abandoned data (keyed on last-access, so active
        # datasets are never evicted). The capacity sweep (>85%) still runs on top.
        maxIdleDays = 180;
      };
    };
  };

  # Node-local fast per-user cache at /local/<user> (modules/local-cache.nix). The
  # counterpart to scratch above: where /scratch/krg overflows cold data to fabricant
  # NFS when it fills, /local is a plain durable NVMe dataset that never overflows
  # (nvmepool/local, off the @blank rollback) for the regenerable, hot, NODE-local
  # state that should NOT live on the NFS /home — the IDE remote servers
  # (~/.vscode-server, ~/.cursor-server, symlinked in on login) and the cache class
  # (XDG_CACHE_HOME, Hugging Face / torch / conda-pkgs / npm). On a CUDA box this is
  # the big NFS-offload win: HF model downloads and vscode-server's small-file/watch
  # traffic stay on local NVMe instead of hammering fabricant.
  #
  # Defaults (modules/local-cache.nix) cover the symlinks + cache env vars, so just
  # enabling perUser is enough. MIGRATION: an existing real ~/.vscode-server on NFS is
  # never clobbered — a user opts in once with `rm -rf ~/.vscode-server`, then the next
  # login creates the symlink. On-box: `zfs create -o mountpoint=legacy -o quota=1T \
  # -o com.sun:auto-snapshot=false nvmepool/local` before deploying (disko isn't re-run
  # live; same as the scratch datasets).
  krg.localCache = {
    enable = true;
    perUser.enable = true;
  };

  # Swap = zram (no on-disk swap; ZFS swap zvols are deadlock-prone under memory
  # pressure). zstd-compressed RAM cushion for OOM bursts. memoryPercent is a cap on
  # the zram device size, not a reservation. Interacts with earlyoom + the ARC cap below.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # --- Concurrency & memory contention (greenfield scratch redesign) ----------
  # Multiple mixed workloads (GPU/CPU/FPGA) share this box and one finite NVMe cache.
  # Cap the ZFS ARC so it can't starve a RAM-hungry job, and run earlyoom so real
  # memory pressure is handled gracefully instead of a hard OOM/livelock.
  #
  # ARC cap: 96 GiB (~25% of the 377 GiB installed). Leaves ~280 GiB for ML jobs while
  # giving scratch a solid RAM cache on top of the ~5.6 TiB L2ARC — whose ARC header
  # overhead is only ~0.4 GB at the 1M scratch recordsize, so the L2ARC is nearly free.
  # ZFS default would be ~50% (~188 GiB), too much to hand a shared ML box. Tune with
  # arcstat if the hit-rate is starved or jobs need more RAM. Threadripper PRO 7985WX.
  krg.zfs.arcMaxBytes = 96 * 1024 * 1024 * 1024;

  # Add the node_exporter `zfs` collector (on top of the default systemd/mdadm/textfile
  # set) so node_zfs_arc_* metrics — ARC/L2ARC size + hit ratio — reach Prometheus.
  # The ARC/L2ARC is the core of the scratch read-path design (96 GiB ARC + ~5.6 TiB
  # L2ARC), so its hit-rate is the signal that tells us scratch is performing; the
  # "ZFS & Storage Health" panels on the Waiter Grafana dashboard read these. Pool
  # health itself still comes from the krg.zfs zpool-health textfile metric.
  krg.nodeExporter.collectors = ["systemd" "mdadm" "textfile" "zfs"];

  # earlyoom: kill the worst memory hog early (before the kernel OOM killer livelocks
  # under ZFS ARC + zram pressure). Disable systemd-oomd (PSI-based, fights ARC
  # accounting) in favour of it. This is the deferred base.nix earlyoom item, landed
  # here for waiter (the box that actually needs it) as part of this redesign.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5; # act when <5% RAM free
    freeSwapThreshold = 10;
  };
  systemd.oomd.enable = false;

  # smartd: monitor the physical disks (the redesign's striped scratchpool has NO
  # redundancy, so advance warning of a failing disk matters — esp. the historically
  # flaky sdb). No MTA here, so escalate via wall + the journal; the zpool-health
  # textfile collector (modules/zfs.nix) covers pool-level state for Prometheus.
  services.smartd = {
    enable = true;
    autodetect = true;
    notifications.wall.enable = true;
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)"; # short daily 02:00, long weekly Sat 03:00
  };

  # FPGA/EDA toolchain (Vivado/Vitis/Questa/Verilator) stays OFF pending sign-off from
  # the other researchers. FPGA is opt-in in the compute profile now, so this is
  # explicit/deliberate — waiter IS the FPGA box, so flip to true once confirmed.
  # The /tools dataset is unaffected (modules/hardware/fpga.nix).
  krg.fpga.enable = true;

  # Login access: Domain Admins (infra admins — own-account login + sudo) PLUS the
  # "Waiter" AD group (this box's researchers). Overrides base.nix's Domain-Admins-only
  # default. Break-glass krg-admin (local) is unaffected. NOTE: the "Waiter" AD group
  # must exist and have members (AD-side, see docs/creating-a-user.md); it's matched
  # under CN=Users — use krg.adClient.accessFilter if it ever lives in a custom OU.
  krg.adClient.allowedGroups = ["Domain Admins" "Waiter"];

  # Technology control plan: the ARM PDK engineers and everyone who can sudo must use
  # waiter's desktop ONLY over an auditable SSH tunnel, never the one-click Guacamole
  # browser RDP. Guacamole can't enforce this (its admins are superusers), so the gate
  # lives in xrdp's auth and keys on the RDP source IP — Guacamole arrives from krg-prod
  # (krg.firewall.rdpSources, inherited as gatewayDeny.sources), the SSH tunnel from
  # loopback. "ARM PDK Access" plus krg.adClient.sudoGroups (Domain Admins) plus local
  # wheel are denied from the gateway origin; everyone else keeps clientless RDP.
  # On-box validation (PAM_RHOST) + caveats: docs/arm-pdk-tcp.md.
  krg.xrdp.gatewayDeny.enable = true;

  networking = {
    hostName = "waiter";
    domain = "ucsd.edu";

    # Static IP on the UCSD-facing onboard NIC. VERIFIED on the installed system
    # via `ip -br link`: name = eno1np0, MAC cc:28:aa:0a:58:fa. The `np0` suffix is
    # the netdev/phys-port of this multi-port onboard NIC (predictable naming) —
    # the earlier guesses enp3s0f0 and eno1 were BOTH wrong. Predictable names are
    # stable per hardware+driver, so this won't drift across reboots/rebuilds; only
    # a NIC swap or major driver change could rename it (then re-check, or pin by
    # MAC with a systemd .link rename).
    useDHCP = false;
    interfaces.eno1np0 = {
      ipv4.addresses = [
        {
          address = "137.110.161.67";
          prefixLength = 24;
        }
      ];
    };
    defaultGateway = "137.110.161.1";
    # The AD DC (krg-ldap) is prepended as the PRIMARY resolver by krg.adClient
    # (modules/sssd-ad-client.nix) for every domain member — so SSSD can resolve the
    # internal krg.local zone instead of flapping offline. These are just waiter's
    # site fallbacks, used after the DC.
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];

    # ZFS requires a unique hostId — generate with:
    #   python3 -c "import uuid; print(str(uuid.uuid4())[:8])"
    # and set it here.
    hostId = "34658941";
  };

  # Qualys/Trellix agents are enabled for all hosts in base.nix. The installer
  # archive is referenced by a runtime path (default
  # /var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz) so its embedded
  # credentials never enter the Nix store — place it there out-of-band:
  #   scp oec-qualystrellixinstallers-linux.tgz waiter:/var/lib/krg/oec/
  # then rebuild; the oec-install service enrolls the agents on next boot.

  # GNU Make for researchers building from source on this workstation.
  environment.systemPackages = [pkgs.gnumake];

  system.stateVersion = "25.11";
}
