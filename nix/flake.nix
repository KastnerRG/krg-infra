{
  description = "KRG NixOS Flakes - Infrastructure configuration replacing Ansible";

  inputs = {
    # Latest NixOS stable (release branch, not unstable): production rebuilds and
    # the nightly autoUpgrade then only pull backported fixes, not rolling churn.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

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

    # Tree formatter. alejandra is the repo's chosen .nix formatter; treefmt-nix
    # exposes it as `nix fmt` and, more importantly, as a `nix flake check` gate
    # (checks.formatting below) so unformatted Nix fails CI. See KastnerRG/krg-infra#150.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    treefmt-nix,
    ...
  } @ inputs: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # alejandra-only treefmt config; projectRootFile anchors it at nix/flake.nix.
    treefmtEval = treefmt-nix.lib.evalModule pkgs {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };

    mkSystem = hostname:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          {_module.args.self = self;}
          ./hosts/${hostname}/default.nix
        ];
      };

    # The Incus GOLDEN TEMPLATE (ADR 0017 §7, gate 3) — the shared hardened NixOS system
    # every tenant instance boots from. NOT a fleet host (it's never nixos-rebuilt onto a
    # machine and is absent from deploy/lib.sh); it lives in nixosConfigurations only so
    # CI type-checks + builds its toplevel and base.nix's autoUpgrade #krg-golden resolves.
    # Its image artifacts (config.system.build.qemuImage / .metadata, from
    # nix/golden/default.nix's incus-virtual-machine import) are built + published to
    # krg-nat by deploy/incus-publish-golden.sh. Built inline (not mkSystem) because it's
    # under golden/, not hosts/.
    golden = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {inherit inputs;};
      modules = [
        {_module.args.self = self;}
        ./golden/default.nix
      ];
    };
  in {
    # `nix fmt` → alejandra via treefmt.
    formatter.${system} = treefmtEval.config.build.wrapper;

    # `nix flake check` gates.
    checks.${system} = {
      # Fails on any unformatted .nix in the tree.
      formatting = treefmtEval.config.build.check self;

      # Contract self-test (ADR 0020): force-evaluate a sample mkTenant call AND a tenant
      # nixosConfiguration built from it, asserting the spec projection + the module
      # wiring. Catches a contract regression at `nix flake check` time even though no
      # host in this flake instantiates nixosModules.tenant (tenants live in their own repos).
      mkTenant-contract = let
        spec = self.lib.mkTenant {
          name = "example";
          zone = "e4e";
          hostname = "example.e4e.ucsd.edu";
          sso.group = "example";
          resources = {
            cpu = 4;
            ram = "8GiB";
          };
          compose = ./templates/tenant/deploy/compose.yml;
          repo = "UCSD-E4E/example";
          temporal = {namespace = "example";};
        };
        sys = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {inherit inputs;};
          modules = [
            self.nixosModules.tenant
            {krg.tenant = spec;}
          ];
        };
        # Spec shape: the admin-side terraform projection + the boundary fields.
        shapeOk =
          spec.terraformTenant.zone
          == "e4e"
          && spec.terraformTenant.memory == "8GiB"
          && spec.terraformTenant.cpu == 4
          && spec.boundary.sso.group == "example"
          && spec.boundary.kvPrefix == "tenants/example"
          && spec.boundary.temporal.namespace == "example"
          && spec.interior.compose != null;
        # Module wiring: the spec drives the hostname + the compose stack; a tenant with a
        # compose gets the in-instance vault-agent that mints its <tenant>.vm cert (ADR 0021);
        # and a tenant with a repo gets the repo-owns-deploy runner + its self-update unit
        # (ADR 0022). Forcing the openbao-agent + selfupdate unit scripts here type-checks
        # those render/switch blocks in CI, so neither seam can silently break eval.
        moduleOk =
          sys.config.networking.hostName
          == "example"
          && (sys.config.krg.composeStacks ? "example")
          && sys.config.krg.vaultAgent.roleName == "tenant-example"
          && builtins.isString "${sys.config.systemd.services.openbao-agent.serviceConfig.ExecStart}"
          && sys.config.services.github-runners.example.url == "https://github.com/UCSD-E4E/example"
          && builtins.isString "${sys.config.systemd.services.example-selfupdate.script}"
          # a tenant that requested temporal gets the temporal-client render (ADR 0023 §2)
          && builtins.any (r: r.destination == "/run/tenant/temporal/tls.crt") sys.config.krg.vaultAgent.renders
          # committed config MUST apply on converge (issue #458): the tenant stack force-recreates
          && nixpkgs.lib.hasInfix "--force-recreate" sys.config.systemd.services.example.serviceConfig.ExecStart
          # the nightly auto-upgrade targets the TENANT's own flake, not krg-infra's (else it
          # fails silently every night — no system patches). #<name> = the tenant's own config.
          && sys.config.system.autoUpgrade.flake == "github:UCSD-E4E/example#example";
      in
        assert shapeOk;
        assert moduleOk;
          pkgs.runCommand "mktenant-contract-ok" {} "touch $out";
    };

    # The tenant-facing contract surface (ADR 0020 §1) — narrow + secret-free, pinned by
    # tenant repos. Kept separate from the flake's internals on purpose.
    lib.mkTenant = import ./lib/mk-tenant.nix {inherit (nixpkgs) lib;};

    nixosModules = {
      base = import ./profiles/base.nix;
      docker = import ./modules/docker.nix;
      users = import ./modules/users.nix;
      zfs = import ./modules/zfs.nix;
      nix-ld = import ./modules/nix-ld.nix;
      impermanence = import ./modules/impermanence.nix;

      compose-stack = import ./modules/services/compose-stack.nix;
      node-exporter = import ./modules/services/node-exporter.nix;
      ipmi-exporter = import ./modules/services/ipmi-exporter.nix;

      samba-ad = import ./modules/samba-ad.nix;
      ad-client = import ./modules/sssd-ad-client.nix;
      incus = import ./modules/incus.nix;
      tenant = import ./modules/tenant.nix; # the NixOS half of the deploy contract (ADR 0020)

      firewall = import ./modules/security/firewall.nix;
      crowdsec = import ./modules/security/crowdsec.nix;
      crowdsec-bouncer = import ./modules/security/crowdsec-bouncer.nix;
      oec-qualys-trellix = import ./modules/security/oec-qualys-trellix.nix;

      nvidia = import ./modules/hardware/nvidia.nix;
      fpga = import ./modules/hardware/fpga.nix;
      ipmi-lan = import ./modules/hardware/ipmi-lan.nix;

      xrdp = import ./modules/desktop/xrdp.nix;
      edge = import ./modules/edge.nix; # per-zone public edge (ADR 0017 §5)
    };

    nixosConfigurations = {
      krg-prod = mkSystem "krg-prod"; # KRG lab-wide production (was "fabricant")
      e4e-prod = mkSystem "e4e-prod"; # E4E project-specific production
      waiter = mkSystem "waiter";
      kastner-ml = mkSystem "kastner-ml"; # E4E GPU compute box (RTX A6000)
      krg-ldap = mkSystem "krg-ldap";
      krg-vault = mkSystem "krg-vault"; # OpenBao secrets manager
      krg-deploy = mkSystem "krg-deploy"; # Ansible control node + OpenTofu
      krg-nat = mkSystem "krg-nat"; # Incus platform host (ADR 0017)
      krg-golden = golden; # the Incus golden template (ADR 0017 §7); an IMAGE, not a deployed host
    };

    # `nix flake init -t github:KastnerRG/krg-infra?dir=nix#tenant` — a tenant repo
    # skeleton: pin krg-infra + one mkTenant declaration + a compose interior (ADR 0020).
    templates = {
      tenant = {
        path = ./templates/tenant;
        description = "A KRG Incus platform tenant (mkTenant deploy contract)";
      };
      default = self.templates.tenant;
    };
  };
}
