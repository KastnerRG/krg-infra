{
  description = "A KRG platform tenant — declares its deploy target via krg-infra's mkTenant contract (ADR 0020)";

  inputs = {
    # Pin krg-infra at a REV — the pinned rev IS your stable contract. Bump it
    # deliberately to pick up deploy-contract changes (ADR 0020 §5). The tenant-facing
    # surface (lib.mkTenant / nixosModules.tenant) is kept narrow + secret-free, so this
    # input never drags in fabricant's host configs or secrets.
    krg-infra.url = "github:KastnerRG/krg-infra?dir=nix";
    nixpkgs.follows = "krg-infra/nixpkgs";
  };

  outputs = {
    self,
    krg-infra,
    nixpkgs,
  }: let
    system = "x86_64-linux";

    # ── THE DECLARATION ───────────────────────────────────────────────────────────
    # One mkTenant call. Split into interior (yours, authoritative) and boundary
    # (requests an admin provisions — you cannot self-grant a route/quota/CNAME).
    tenant = krg-infra.lib.mkTenant {
      name = "example"; # your slug (Incus project + OpenBao role + runner scope)
      zone = "e4e"; # which public edge routes to you: "krg" | "e4e"
      hostname = "example.e4e.ucsd.edu"; # the CNAME you request
      sso.group = "example"; # AD group gating access at the edge
      resources = {
        cpu = 4;
        ram = "8GiB";
      }; # quota request
      compose = ./deploy/compose.yml; # YOUR interior — repo-owns-deploy
      # image = "...";                   # set to launch the slot from the golden template
      repo = "UCSD-E4E/example"; # runner scope (informational in the spec)
    };
  in {
    # The deploy target: a NixOS instance built from THIS flake (ADR 0020 §2 — "the
    # project flake defines its deploy target" is literally true). The admin-provisioned
    # Incus slot is built from your own config.
    nixosConfigurations.${tenant.name} = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        krg-infra.nixosModules.tenant
        {krg.tenant = tenant;}
        # ./hardware-configuration.nix   # your instance's disk/boot (captured at bring-up)
      ];
    };

    # The admin-side spec→provision projection. An admin reviewing your onboarding PR
    # copies `terraformTenant` straight into terraform/incus's `var.tenants` (no
    # translation) and files the CNAME. Boundary stays admin-provisioned.
    #   nix eval .#krgTenant.terraformTenant --json
    krgTenant = tenant;
  };
}
