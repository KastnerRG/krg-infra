# fishsense-lite deploy target — the INTERIOR half of the mkTenant contract (ADR 0020).
#
# Copy this into UCSD-E4E/fishsense-lite as `flake.nix` (adjust the pinned rev + your
# hardware-configuration.nix). One `mkTenant` call declares the deploy target; the fields
# split into interior (yours, authoritative) and boundary (requests an admin provisioned —
# already done for fishsense, see the HANDOFF.md "what's provisioned" table).
{
  description = "fishsense-lite — KRG Incus platform tenant #1";

  inputs = {
    # PIN a merged krg-infra rev — that rev IS your stable contract (ADR 0020 §5). Bump it
    # deliberately to pick up platform-seam changes. Replace <REV> with a current main SHA
    # >= #431 (has the vault-agent cert wiring AND the repo-owns-deploy runner — see the
    # HANDOFF.md seams table).
    krg-infra.url = "github:KastnerRG/krg-infra/<REV>?dir=nix";
    nixpkgs.follows = "krg-infra/nixpkgs";
  };

  outputs = {
    self,
    krg-infra,
    nixpkgs,
  }: let
    system = "x86_64-linux";

    tenant = krg-infra.lib.mkTenant {
      name = "fishsense"; # Incus project + OpenBao role + runner scope (all already provisioned)
      zone = "e4e"; # fronted by the e4e-prod edge (*.e4e.ucsd.edu)
      hostname = "fishsense.e4e.ucsd.edu"; # the apex CNAME (published; edge serves a prod LE cert)
      sso.group = "FishSense"; # AD group (auth is in-app today; edge SSO is a later seam)
      resources = {
        cpu = 6;
        ram = "12GiB";
      };
      image = "krg-golden"; # the slot boots from the hardened template (already applied)
      compose = ./deploy/compose.yml; # YOUR interior — repo-owns-deploy
      repo = "UCSD-E4E/fishsense-lite"; # LOAD-BEARING: scopes the auto-provisioned runner (ADR 0022)
      # in-VM vault-agent renders a temporal-client cert to /run/tenant/temporal/ (ADR 0023).
      # `reload` = the compose services that DIAL Temporal. The platform re-renders the leaf
      # before it expires, but a worker that builds its TLS config at Client.connect holds the
      # old cert for the life of the process, so it must be restarted on rotation. Naming your
      # worker(s) keeps the restart off your web path; omitting it restarts the whole stack.
      temporal = {
        namespace = "fishsense";
        reload = ["fishsense-api-workflow-worker"];
      };
    };
  in {
    # The Incus slot (already booted at 10.100.0.10) converges to THIS config via your
    # runner (repo-owns-deploy). nixosModules.tenant brings the lab baseline (AD-join,
    # firewall, CrowdSec, monitoring) + Docker + the compose runner.
    nixosConfigurations.fishsense = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        krg-infra.nixosModules.tenant
        {krg.tenant = tenant;}
        # ./hardware-configuration.nix   # capture from the running slot at bring-up:
        #   incus exec fishsense --project fishsense -- nixos-generate-config --show-hardware-config
      ];
    };

    # Admin projection — already copied into krg-infra terraform/incus var.tenants.fishsense
    # (plus the admin-only nat_ip=10.100.0.10 + edge_port=30443). Kept so the boundary stays
    # reproducible: `nix eval .#krgTenant.terraformTenant --json`.
    krgTenant = tenant;
  };
}
