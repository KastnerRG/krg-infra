# Campus-mandated endpoint security agents: Qualys Cloud Agent (vulnerability
# management) and Trellix Endpoint Security HX / xagt (EDR + anti-malware).
#
# CROSS-REFERENCE: the Proxmox-host counterpart is ansible/roles/oec_qualys_trellix
# (native .deb install via the vendor script). Same agents — keep the installer
# archive + enrollment in sync across both layers.
#
# These are proprietary Ubuntu/CentOS .deb/.rpm binaries with no nixpkgs
# package. They are NOT installed via the vendor installer (which uses
# dpkg/yum/systemctl and won't work on NixOS). Instead we:
#   1. run them under nix-ld — both binaries use the standard
#      /lib64/ld-linux-x86-64.so.2 interpreter and only need glibc +
#      libstdc++/libgcc_s from the system; the rest of their libraries are
#      bundled and resolved via RPATH (/opt/fireeye/lib, /usr/local/qualys/...);
#   2. extract the .deb payloads to their expected FHS paths and enroll them
#      once, via the oec-install one-shot service (after network-online);
#   3. run the daemons with the vendor's own unit semantics.
#
# The installer archive is referenced by a RUNTIME path (not a Nix store path)
# so the credentials it contains never land in the world-readable Nix store.
# Place it out-of-band at krg.oecQualysTrellix.installerArchive (default
# /var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib; let
  cfg = config.krg.oecQualysTrellix;

  # System libraries the agents need at runtime under nix-ld. glibc +
  # libstdc++/libgcc_s cover the base; the agents' bundled .so's additionally
  # need libblkid.so.1 (util-linux) and libmagic.so.1 (file), which xagt does
  # not ship. Everything else the agents need is bundled and found via RPATH.
  agentLibs = with pkgs; [stdenv.cc.cc.lib glibc util-linux.lib file];

  # A full PATH for the agents and their helper scripts. The Qualys agent's
  # command-runner shells out to chown/chmod/ls/ps/awk/sed and (via envfs)
  # /bin/bash, /usr/bin/systemd-run; a minimal PATH makes those fail and the
  # agent aborts with a SwitchUserError. systemd is included so the activation's
  # qagent_restart.sh finds systemctl.
  agentPath = makeBinPath (with pkgs; [
    bash
    coreutils
    gnused
    gnugrep
    gawk
    findutils
    procps
    util-linux
    systemd
  ]);

  # Loader + PATH environment for the unpatched vendor binaries (see header).
  nixLdEnv = [
    "NIX_LD=${pkgs.glibc}/lib/ld-linux-x86-64.so.2"
    "NIX_LD_LIBRARY_PATH=${makeLibraryPath agentLibs}"
  ];
  agentEnv = nixLdEnv ++ ["PATH=${agentPath}"];

  # One-time installer: extract the .deb payloads to /opt/fireeye and
  # /usr/local/qualys, drop the Trellix config, and enroll both agents.
  # Qualys ActivationId/CustomerId are read FROM THE ARCHIVE (vendor script)
  # so they never enter the Nix store.
  oecInstall = pkgs.writeShellScriptBin "oec-install" ''
    set -euo pipefail
    # dpkg/tar/gzip for extraction; the rest for the Qualys activation script
    # (qualys-cloud-agent.sh + qagent_restart.sh use awk/sed/ps/systemctl, etc.).
    export PATH=${makeBinPath (with pkgs; [dpkg gnutar gzip bash coreutils gnused gnugrep gawk findutils procps util-linux systemd])}:$PATH

    ARCHIVE="''${1:?usage: oec-install <path-to-oec-archive.tgz>}"
    [ -r "$ARCHIVE" ] || { echo "oec-install: archive not readable: $ARCHIVE" >&2; exit 1; }

    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    echo "oec-install: extracting $ARCHIVE"
    tar -xzf "$ARCHIVE" -C "$STAGE"
    SRC="$STAGE/trellixandqualys"
    [ -d "$SRC" ] || { echo "oec-install: unexpected archive layout" >&2; exit 1; }

    # ── Trellix xagt → /opt/fireeye ───────────────────────────────────────
    # Install + enroll only if not already enrolled. Gating the whole block on
    # main.db makes retries safe: xagt.service only runs once main.db exists, so
    # when this block runs the binary is never live ("Text file busy"), and a
    # retry after a later (Qualys) failure won't re-import or re-copy.
    if [ ! -e /var/lib/fireeye/xagt/main.db ]; then
      echo "oec-install: installing + enrolling Trellix xagt"
      dpkg-deb -x "$SRC/xagt_36.21.0-1.ubuntu16_amd64.deb" "$STAGE/xagt"
      mkdir -p /opt/fireeye /var/lib/fireeye
      cp -a "$STAGE/xagt/opt/fireeye/." /opt/fireeye/
      cp -a "$STAGE/xagt/var/lib/fireeye/." /var/lib/fireeye/
      install -m 0600 "$SRC/agent_config.json" /opt/fireeye/agent_config.json
      /opt/fireeye/bin/xagt -i /opt/fireeye/agent_config.json
    else
      echo "oec-install: Trellix already enrolled (main.db present), skipping"
    fi

    # ── Qualys Cloud Agent → /usr/local/qualys ────────────────────────────
    # Copy files only if not already installed, to avoid overwriting the running
    # qualys-cloud-agent binary on a retry. Activation runs every time the
    # service runs (i.e. until it succeeds and writes the sentinel below).
    if [ ! -x /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent ]; then
      echo "oec-install: installing Qualys Cloud Agent"
      dpkg-deb -x "$SRC/qualys_cloud_agent.deb" "$STAGE/qualys"
      mkdir -p /usr/local/qualys /etc/qualys /var/log/qualys /var/spool/qualys
      cp -a "$STAGE/qualys/usr/local/qualys/." /usr/local/qualys/
      cp -a "$STAGE/qualys/etc/qualys/." /etc/qualys/
    fi
    # The .deb postinst (skipped by dpkg-deb -x) creates these dirs; without
    # them the agent aborts at startup ("File not found: .../manifests").
    mkdir -p /usr/local/qualys/cloud-agent/manifests /usr/local/qualys/cloud-agent/correlation/manifests
    chmod 700 /usr/local/qualys/cloud-agent/manifests /usr/local/qualys/cloud-agent/correlation /usr/local/qualys/cloud-agent/correlation/manifests
    ACT="$(grep -oE 'ActivationId=[0-9a-fA-F-]+' "$SRC/install_ubuntu.sh" | head -1 | cut -d= -f2 || true)"
    CID="$(grep -oE 'CustomerId=[0-9a-fA-F-]+' "$SRC/install_ubuntu.sh" | head -1 | cut -d= -f2 || true)"
    if [ -n "$ACT" ] && [ -n "$CID" ]; then
      echo "oec-install: activating Qualys"
      bash /usr/local/qualys/cloud-agent/bin/qualys-cloud-agent.sh ActivationId="$ACT" CustomerId="$CID"
    else
      echo "oec-install: WARNING — Qualys ActivationId/CustomerId not found in archive; skipping activation" >&2
    fi

    # Success sentinel — set -e means we only reach this if every step above
    # succeeded. The oec-install service is gated on its ABSENCE, so a failed
    # run (e.g. enrollment error) re-runs on the next rebuild; remove it to
    # force a reinstall.
    touch /var/lib/krg/oec/.installed
    echo "oec-install: done"
  '';
in {
  options.krg.oecQualysTrellix = {
    enable = mkEnableOption "OEC Qualys Cloud Agent and Trellix HX (xagt) security agents";

    # RUNTIME path to the installer archive (NOT a Nix store path — keeps the
    # embedded credentials out of the store). Place the archive here out-of-band
    # (scp / sops-nix later). If absent at boot, install is skipped and the
    # agents stay dormant until it is provided and the host is rebuilt.
    installerArchive = mkOption {
      type = types.str;
      default = "/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz";
      description = "Runtime path to oec-qualystrellixinstallers-linux.tgz";
    };

    qualysBin = mkOption {
      type = types.str;
      default = "/usr/local/qualys/cloud-agent/bin/qualys-cloud-agent";
    };

    trellixBin = mkOption {
      type = types.str;
      # The xagt .deb installs under /opt/fireeye (confirmed by the vendor
      # install_ubuntu.sh and the package layout).
      default = "/opt/fireeye/bin/xagt";
    };

    enableTrellix = mkOption {
      type = types.bool;
      default = true;
      description = "Run the Trellix xagt daemon (Qualys is always run when enabled)";
    };
  };

  config = mkIf cfg.enable {
    # Make the unpatched vendor ELF binaries (and any helpers they exec) runnable.
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = agentLibs;

    # The vendor shell scripts (and the running agents) assume an FHS layout —
    # e.g. /bin/bash shebangs and /usr/bin/systemd-run. envfs makes /bin/* and
    # /usr/bin/* resolve to whatever is on PATH, so those work at install and
    # runtime without per-path symlinks.
    services.envfs.enable = true;
    # Pin envfs 1.2.0 over nixpkgs 25.11's deadlock-prone 1.1.0. The 1.1.0 mount.envfs
    # FUSE daemon wedges (processes hang uninterruptibly in request_wait_answer); since
    # /bin/sh + /usr/bin/env exec through this mount, one stuck daemon blocks every new
    # process launch and every AD SSH login. Fixed by 1.2.0's O_PATH path resolution.
    # See flake.nix for the full story + when to drop this (tracked in
    # KastnerRG/krg-infra#82). Applies wherever envfs is enabled (fleet-wide, base->oec).
    #
    # We build from the pinned source ourselves rather than use the envfs flake's own
    # package output: upstream's default.nix vendors with `cargoLock.lockFile`, which on
    # nixpkgs 25.11 fetches crates via the legacy crates.io/api/v1 endpoint — that now
    # returns HTTP 403, so the build dies (e.g. concurrent-hashmap). Using `cargoHash`
    # instead routes through fetchCargoVendor -> static.crates.io (the default vendorer
    # in 25.11), which works. Upstream tracking: Mic92/envfs#145. If the pinned rev
    # changes, recompute cargoHash (build once with lib.fakeHash, read the "got:" hash).
    services.envfs.package = pkgs.rustPlatform.buildRustPackage {
      pname = "envfs";
      version = "1.2.0-unstable-8a2a7066"; # Cargo.toml still says 1.1.0; rev 8a2a7066 carries the fix
      src = inputs.envfs;
      cargoHash = "sha256-dz3gpE464jnmSDsAsmJHcxUsEKeUURNoUjgGU2214Xg=";
      postInstall = ''
        ln -s envfs $out/bin/mount.envfs
        ln -s envfs $out/bin/mount.fuse.envfs
      '';
    };

    # Where the admin drops the installer archive.
    systemd.tmpfiles.rules = ["d /var/lib/krg/oec 0700 root root -"];

    # Manual re-run helper: `oec-install /path/to/archive.tgz`
    environment.systemPackages = [oecInstall];

    # One-time install + enrollment, after the network is up. Runs only when the
    # archive is present and xagt isn't installed yet.
    systemd.services.oec-install = {
      description = "Install and enroll Qualys + Trellix agents (one-time)";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      # Not ordered Before qualys-cloud-agent: the Qualys activation calls
      # qagent_restart.sh which runs `systemctl restart qualys-cloud-agent`, and
      # an ordering cycle there would deadlock. qualys-cloud-agent is gated on
      # its binary existing instead.
      before = ["xagt.service"];
      # Wait for the envfs /bin and /usr/bin mounts so /bin/bash etc. exist when
      # the vendor scripts run (also orders correctly on the switch that first
      # enables envfs).
      unitConfig.RequiresMountsFor = ["/bin" "/usr/bin"];
      unitConfig.ConditionPathExists = [cfg.installerArchive "!/var/lib/krg/oec/.installed"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = agentEnv;
        ExecStart = "${oecInstall}/bin/oec-install ${cfg.installerArchive}";
      };
    };

    # Qualys Cloud Agent daemon (vendor unit: simple, restart on-failure).
    systemd.services.qualys-cloud-agent = {
      description = "Qualys Cloud Agent";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      unitConfig.ConditionPathExists = cfg.qualysBin;
      serviceConfig = {
        Type = "simple";
        Environment = agentEnv;
        ExecStart = cfg.qualysBin;
        Restart = "on-failure";
        RestartSec = 60;
        TimeoutStopSec = 90;
      };
    };

    # Trellix Endpoint Security HX agent (vendor unit: xagt -M DAEMON, gated on
    # the enrollment db so it only starts after oec-install has run).
    systemd.services.xagt = mkIf cfg.enableTrellix {
      description = "Trellix Endpoint Security HX agent (xagt)";
      after = ["oec-install.service" "network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      unitConfig.ConditionPathExists = "/var/lib/fireeye/xagt/main.db";
      serviceConfig = {
        Type = "simple";
        Environment = agentEnv;
        ExecStart = "${cfg.trellixBin} -M DAEMON";
        KillMode = "process";
        Restart = "always";
        RestartSec = 10;
      };
    };
  };
}
