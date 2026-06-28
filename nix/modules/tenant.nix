# nixosModules.tenant — the NixOS half of the deploy contract (ADR 0020 §1/§4).
#
# A NixOS-instance tenant imports this and sets `krg.tenant` to its lib.mkTenant spec:
#
#   # <project>/flake.nix
#   nixosConfigurations.<name> = nixpkgs.lib.nixosSystem {
#     modules = [
#       krg-infra.nixosModules.tenant
#       { krg.tenant = krg-infra.lib.mkTenant { name = "..."; zone = "e4e"; ... }; }
#       ./hardware-configuration.nix   # the instance's disk/boot (tenant-owned)
#     ];
#   };
#
# Consuming it brings the lab baseline (AD-join, in-guest firewall, CrowdSec, OEC,
# monitoring — via profiles/server.nix) plus Docker + the compose runner, and wires the
# tenant's compose INTERIOR as a managed stack. The interior is tenant-owned and
# authoritative (repo-owns-deploy): the runner updates the compose; nix just runs it.
#
# DELIBERATELY NOT YET WIRED (gated on later track PRs, flagged so the seam is explicit):
#   • the repo-scoped GitHub runner (needs the GitHub App credential path),
#   • the edge re-encrypt cert (vault-agent issuing `tenant-internal` from the per-tenant
#     AppRole — terraform/openbao tenants.tf landed in #374; the agent wiring is next),
#   • OEC enrollment follows persistence (ADR 0017 §7) — a persistent tenant enrolls, an
#     ephemeral one is exempt; base.nix enables OEC, so persistent tenants are covered.
# These attach here as they land WITHOUT changing the tenant-facing contract surface.
{
  config,
  lib,
  ...
}:
with lib; let
  t = config.krg.tenant;
  hasTenant = t != {};
  hasCompose = hasTenant && (t.interior.compose or null) != null;
in {
  imports = [
    ../profiles/server.nix # the lab baseline (base + monitoring)
    ./docker.nix
    ./services/compose-stack.nix
  ];

  options.krg.tenant = mkOption {
    type = types.attrs;
    default = {};
    description = ''
      The `lib.mkTenant` spec for this instance — the whole returned attrset. Set it
      from the tenant flake (`krg.tenant = krg-infra.lib.mkTenant { ... };`); the module
      reads `.name`, `.boundary.sso.group`, `.interior.compose`, etc. from it. Empty
      (the default) leaves the module inert — it contributes only its baseline imports.
    '';
  };

  config = mkIf hasTenant (mkMerge [
    {
      # Baseline + identity. Hostname follows the tenant slug; the network is DHCP from
      # the Incus NAT (the platform assigns the RFC1918 address — see terraform/incus).
      krg.base = {
        enable = true;
        isVM = true; # Incus VM-type instance (the untrusted-tenant isolation tier)
      };
      krg.adminAccount = mkDefault "krg-admin"; # admins own boundary + break-glass recovery
      krg.docker.enable = true;

      networking.hostName = mkDefault t.name;
      networking.useDHCP = mkDefault true; # Incus NAT DHCP

      system.stateVersion = mkDefault "25.11";
    }

    (mkIf hasCompose {
      # The tenant's compose, run as a managed stack under /var/lib/krg/<name>. The
      # INTERIOR is tenant-owned: the runner ships updates via merged auto-deploy PRs
      # (ADR 0017 §8); nix only declares the stack that runs it.
      krg.composeStacks.${t.name}.composeFiles = [(toString t.interior.compose)];
    })
  ]);
}
