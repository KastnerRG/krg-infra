{
  description = "KRG NixOS Flakes - Infrastructure configuration replacing Ansible";

  inputs = {
    # Latest NixOS stable (release branch, not unstable): production rebuilds and
    # the nightly autoUpgrade then only pull backported fixes, not rolling churn.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Declarative disk partitioning/formatting (waiter's ZFS layout). Pin its
    # nixpkgs to ours so disko's lib matches the system being built.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # "Erase your darlings" — bind-mounted /persist state over an ephemeral root.
    # Pin its nixpkgs to ours (same as disko) so it doesn't drag in a second
    # nixpkgs at nixos-unstable — keeps the whole flake on the pinned stable tree.
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # envfs serves /bin and /usr/bin via a FUSE daemon (mount.envfs); enabled
    # fleet-wide by the oec module (the vendor agents + nix-ld need an FHS layout).
    # nixpkgs 25.11 ships envfs 1.1.0, whose FUSE daemon DEADLOCKS: processes wedge
    # uninterruptibly in fuse_dentry_revalidate -> request_wait_answer, and because
    # nearly everything execs through /bin/sh or /usr/bin/env, one stuck daemon blocks
    # EVERY new process launch (and every AD SSH login — sshd's AuthorizedKeysCommand
    # is a /bin/sh wrapper). Observed on waiter (kernel 6.12.90) and chris-laptop
    # (7.0.9), ending in hung-task warnings + a watchdog reboot. Fixed upstream in
    # 1.2.0 ("Avoid FUSE deadlocks by resolving paths with O_PATH fds"); nixpkgs has
    # NOT merged it (PR NixOS/nixpkgs#500707), so `nix flake update` does not help.
    # Pin 1.2.0 here as the SOURCE and build it with our own rustPlatform in the oec
    # module (services.envfs.package). We do NOT use this flake's own package output:
    # envfs's default.nix vendors via `cargoLock.lockFile`, which on nixpkgs 25.11
    # fetches crates from the legacy crates.io/api/v1 endpoint — now HTTP 403, so that
    # build fails (e.g. concurrent-hashmap). Building with `cargoHash` instead uses
    # fetchCargoVendor -> static.crates.io and works (see the oec module). The version
    # string in Cargo.toml is still 1.1.0 (upstream never bumped it for the 1.2.0 tag),
    # but rev 8a2a7066 carries the O_PATH fix. Drop this input once #500707 lands and
    # `nix flake update` picks up a fixed envfs (tracked in KastnerRG/krg-infra#82;
    # upstream crates.io-403 context: Mic92/envfs#145).
    envfs = {
      url = "github:Mic92/envfs/1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
  let
    system = "x86_64-linux";

    mkSystem = hostname: nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        { _module.args.self = self; }
        ./hosts/${hostname}/default.nix
      ];
    };
  in {
    nixosModules = {
      base          = import ./profiles/base.nix;
      docker        = import ./modules/docker.nix;
      users         = import ./modules/users.nix;
      zfs           = import ./modules/zfs.nix;
      nix-ld        = import ./modules/nix-ld.nix;
      impermanence  = import ./modules/impermanence.nix;

      compose-stack  = import ./modules/services/compose-stack.nix;
      node-exporter  = import ./modules/services/node-exporter.nix;
      ipmi-exporter  = import ./modules/services/ipmi-exporter.nix;

      samba-ad      = import ./modules/samba-ad.nix;
      ad-client     = import ./modules/sssd-ad-client.nix;

      firewall           = import ./modules/security/firewall.nix;
      fail2ban           = import ./modules/security/fail2ban.nix;
      oec-qualys-trellix = import ./modules/security/oec-qualys-trellix.nix;

      nvidia = import ./modules/hardware/nvidia.nix;
      fpga   = import ./modules/hardware/fpga.nix;

      xrdp = import ./modules/desktop/xrdp.nix;
    };

    nixosConfigurations = {
      krg-prod    = mkSystem "krg-prod";    # KRG lab-wide production (was "fabricant")
      e4e-prod    = mkSystem "e4e-prod";    # E4E project-specific production
      waiter      = mkSystem "waiter";
      krg-ldap    = mkSystem "krg-ldap";
      krg-vault   = mkSystem "krg-vault";   # OpenBao secrets manager
      krg-deploy  = mkSystem "krg-deploy";  # Ansible control node + OpenTofu
    };
  };
}
