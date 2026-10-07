# e4e-reference-manager deploy target — INTERIOR half of the mkTenant contract (ADR 0020).
#
# COPY-IN HANDOFF: this file belongs at the ROOT of UCSD-E4E/e4e-reference-manager
# (see docs/handoff/reference-manager/HANDOFF.md in krg-infra). It mirrors
# fishsense-services' flake.nix: the platform pieces are identical, only the tenant
# and its interior (deploy/incus/) differ.
#
# `reference-manager-selfupdate` on the slot converges it with
#   nixos-rebuild switch --flake github:UCSD-E4E/e4e-reference-manager#reference-manager
# after a merged `auto-deploy/*` PR (.github/workflows/deploy.yml).
{
  description = "e4e-reference-manager — KRG Incus platform tenant `reference-manager` (bib.krg.ucsd.edu)";

  inputs = {
    # Tracks krg-infra `main`; the EXACT rev is pinned in `flake.lock`, not here.
    # That lock rev is our stable contract (ADR 0020 §5): every converge builds from
    # the committed lock, so `main` moving doesn't touch the slot until the lock is
    # advanced — the deliberate act being a merge to our `main`.
    #
    # Advancing the pin is "Axis B" (krg-infra docs/tenant-updates.md) and it's OURS:
    # `nixpkgs.follows = "krg-infra/nixpkgs"`, so bumping krg-infra drags in new
    # nixpkgs (kernel / bash / openssl / CVE fixes). `.github/workflows/update-flake.yml`
    # does it weekly, and the nightly `system.autoUpgrade` rolls it out. Skip it and the
    # slot freezes on old, unpatched packages. A new kernel needs a manual
    # `incus restart` (allowReboot=false).
    #
    # The FIRST lock must be a krg-infra rev that contains the krg-zone edge (the
    # reference-manager onboarding PR) — any rev after it works.
    krg-infra.url = "github:KastnerRG/krg-infra?dir=nix";
    nixpkgs.follows = "krg-infra/nixpkgs";
  };

  outputs = {
    self,
    krg-infra,
    nixpkgs,
  }: let
    system = "x86_64-linux";

    tenant = krg-infra.lib.mkTenant {
      name = "reference-manager"; # Incus project + OpenBao role tenant-reference-manager + runner scope
      zone = "krg"; # fronted by the krg-prod edge (*.krg.ucsd.edu)
      hostname = "bib.krg.ucsd.edu"; # the CNAME the admin files
      # No sso.group: auth is in-app OIDC (the API's own Authentik client), and the
      # Authentik application is open to every realm user (krg-infra
      # terraform/authentik/reference_manager.tf). Nothing at the edge gates it.
      resources = {
        # What the admin provisioned (krg-infra terraform/incus). GROBID (~4G) + Ollama
        # (qwen2.5:3b + nomic-embed-text, ~4G) dominate; the PDFs live in Garage.
        cpu = 6;
        ram = "12GiB";
        disk = "60GiB";
      };
      image = "krg-golden"; # slot boots from the hardened template
      compose = ./deploy/incus/compose.yml; # YOUR interior — repo-owns-deploy
      # LOAD-BEARING: scopes the auto-provisioned runner (ADR 0022) AND the nightly
      # autoUpgrade / selfupdate flake URL (github:<repo>#reference-manager).
      repo = "UCSD-E4E/e4e-reference-manager";
      # No `temporal`: the app doesn't use the lab's Temporal.
    };
  in {
    # The Incus slot (booted at 10.100.0.11) converges to THIS config via our runner.
    # nixosModules.tenant brings the lab baseline (AD-join, firewall, CrowdSec,
    # monitoring) + Docker + the compose runner + the vault-agent cert render.
    nixosConfigurations.reference-manager = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        krg-infra.nixosModules.tenant
        {krg.tenant = tenant;}
        # Incus VM plumbing — the SAME module the krg-golden image builds from
        # (nix/golden): systemd-boot + ESP/root fileSystems (by label) + incus-agent
        # (keeps `incus exec` working after the switch) + serial console + growPartition.
        ({modulesPath, ...}: {
          imports = [(modulesPath + "/virtualisation/incus-virtual-machine.nix")];
        })
        # Ephemeral VM tier is OEC-exempt — matches krg-golden (nix/golden), which
        # forces this off. base.nix hard-enables OEC; nixosModules.tenant does NOT force
        # it off, so a tenant converging via its own flake must (as fishsense does).
        ({lib, ...}: {
          krg.oecQualysTrellix.enable = lib.mkForce false;
        })
        ./deploy/incus/secrets.nix # extends krg.vaultAgent.renders → /run/tenant/secrets/*.env
        ./deploy/incus/workdir.nix # populate /var/lib/krg/reference-manager so the compose's relative binds resolve
        ./deploy/incus/prune.nix # reclaim superseded images after each converge (GROBID/Ollama are large)
      ];
    };

    # Reproducible boundary projection (admin copies into krg-infra terraform/incus):
    #   nix eval .#krgTenant.terraformTenant --json
    krgTenant = tenant;
  };
}
