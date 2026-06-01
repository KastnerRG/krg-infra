# Waiter-style compute profile: GPU/CUDA, FPGA tools, XRDP desktop, research users.
# Import this in a host's default.nix, then add host-specific compose stacks and users.
{ config, lib, pkgs, ... }: {
  imports = [
    ./base.nix
    ../modules/docker.nix
    ../modules/users.nix
    ../modules/zfs.nix
    ../modules/services/compose-stack.nix
    ../modules/services/ipmi-exporter.nix
    ../modules/hardware/nvidia.nix
    ../modules/hardware/fpga.nix
    ../modules/desktop/xrdp.nix
    ../modules/nix-ld.nix
    ../users/admin.nix
    # Lab users come from Samba AD; only the local break-glass admin stays.
  ];

  krg.base = {
    enable      = true;
    autoUpgrade = true;
  };

  krg.docker = {
    enable              = true;
    enableNvidiaRuntime = true;
    # Bridge the "Docker Users" AD group into the local `docker` group so lab members
    # can use the Docker daemon (the boot+timer AD-group sync from modules/docker.nix
    # → modules/ad-group-sync.nix, the same mechanism as cudaAccessGroups below).
    # Login (krg.adClient.allowedGroups) gates SSH; this gates Docker. NOTE: docker
    # membership is effectively root on the host, so keep "Docker Users" tightly
    # scoped in AD. The group must exist under CN=Users with members (see
    # docs/creating-a-user.md); break-glass krg-admin keeps Docker via
    # krg.users.defaultGroups. Service hosts (krg-prod/e4e-prod) deliberately do NOT
    # get this — it's a compute-profile grant, mirroring GPU Users.
    accessGroups = [ "Docker Users" ];
  };

  krg.zfs = {
    enable       = true;
    autoScrub    = true;
    autoSnapshot.enable = true;
  };

  # krg.fail2ban.enable is set by base.nix (true on every host).

  krg.nvidia = {
    enable     = true;
    openDriver = true;
    # GPU device access (/dev/nvidia*, root:cuda 0770) is gated on the local `cuda`
    # group. AD users can't be put in a fixed-GID local group under idMapping, so a
    # dedicated AD group is bridged in (boot+timer sync — see nvidia.nix). This group
    # gates the GPU; krg.adClient.allowedGroups gates SSH login. The "GPU Users" AD
    # group must exist under CN=Users and have members (see docs/creating-a-user.md).
    cudaAccessGroups = [ "GPU Users" ];
  };

  # FPGA/EDA tooling is OPT-IN, not a compute default: waiter does FPGA research,
  # but kml-class ML boxes don't use it. A host that needs it sets enable = true.
  krg.fpga.enable = lib.mkDefault false;
  # The XRDP/XFCE desktop exists only to host the FPGA GUI tools (Vivado/Vitis/
  # Questa), so it tracks FPGA: a headless compute box (FPGA off) gets no desktop.
  krg.xrdp.enable = true;

  # Native IPMI exporter systemd service (from waiter monitoring.yaml)
  krg.ipmiExporter.enable = true;

  # node_exporter is native via base.nix (services.prometheus.exporters.node on 9100,
  # systemd collector) — same as every other host. Deliberately NOT in waiter's Docker
  # stack: the repo's rule is native systemd exporters, Docker only when needed.

  # Qualys + Trellix are enabled for all machines in base.nix.
  # The installer archive is wired up in hosts/waiter/default.nix.

  # rdp_users is intentionally NOT here — the xrdp module creates and adds it only
  # when XRDP is enabled (which tracks FPGA), so it's not blindly applied everywhere.
  krg.users.defaultGroups = [ "docker" "cuda" ];

  # waiter is physical, so base.nix keeps the NixOS firewall enabled.
  krg.firewall = {
    allowedTCPPorts = [ 22 ];
    allowRDP        = config.krg.xrdp.enable;  # 3389 only when the XRDP desktop is up
    # node-exporter (9100), docker metrics (9323), prometheus client (9000),
    # IPMI exporter (9290). DCGM (9400) is contributed by the nvidia module
    # (krg.nvidia.dcgmExporter), coupled to the driver — not listed here.
    monitoringPorts = [ 9100 9290 9323 9000 ];
  };

  # nix-ld allows running conda, MATLAB, and other dynamically-linked binaries
  # not built for NixOS. Essential for a research workstation.
  krg.nixLd.enable = true;

  # Enable Zsh system-wide (waiter playbook modified /etc/zsh/zshrc for Nix)
  programs.zsh.enable = true;

  # CIFS/SMB mount tooling (e.g. e4e-nas shares) — mirrors kastner-ml's cifs-utils.
  environment.systemPackages = [ pkgs.cifs-utils ];
}
