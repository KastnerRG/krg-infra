# krg.tenantPlatform / krg.tenants — the E4E student-project tenant platform.
#
# WHAT: turns a host into a multi-tenant platform that runs one SEALED microVM per
# student project (ADR 0008). Each tenant is a github repo that owns its own
# deployment: inside its VM run Docker + a repo-scoped self-hosted runner + the
# project's unmodified compose, fronted by a platform edge that terminates public
# TLS and re-encrypts to the VM over the lab OpenBao PKI. This module is the
# substrate — the per-tenant runtime, isolation, and wiring — NOT the projects.
#
# WHY a module (not per-host hand-wiring): the platform is designed to run on more
# than one host concurrently (an `e4e-student` platform and a future `krg-student`
# one), with a SHARED tenant roster partitioned across them. So the mechanism is
# generic (`krg.*`, not `e4e.*`) and assignment is data: each `krg.tenants.<name>`
# carries a `platform` id, and a host instantiates only the tenants whose
# `platform` matches its `krg.tenantPlatform.id`. Reassigning a tenant is a
# one-field change (plus a DNS/cert re-home). See ADR 0008 §1/§6 and
# docs/e4e-prod-tenant-platform.md.
#
# ISOLATION: tenants run as microvm.nix guests (cloud-hypervisor) nested in the
# host, each on a dedicated ZFS zvol — so a compromised/careless deploy is confined
# to its own VM (runner-root = root of that VM, not the host). `isolation` is a
# pluggable knob (`microvm` today) so a tenant can later be moved to a stronger
# boundary without a rewrite.
#
# STATUS: this commit defines the OPTION INTERFACE + host-side enablement scaffold.
# The per-tenant microVM generator (zvol, bridged net, runner, vault-agent, inner
# Traefik + Authentik outpost) and the edge stack land in follow-ups; until then
# enabling the platform asserts its config but generates no guests.
{
  config,
  lib,
  inputs,
  ...
}: let
  cfg = config.krg.tenantPlatform;

  # Tenants assigned to THIS platform instance (platform == our id). Hosts ignore
  # tenants belonging to a sibling platform, so the same roster can be imported
  # everywhere.
  myTenants = lib.filterAttrs (_: t: t.platform == cfg.id) config.krg.tenants;

  tenantModule = {name, ...}: {
    options = {
      platform = lib.mkOption {
        type = lib.types.str;
        example = "e4e-student";
        description = ''
          Which platform instance hosts this tenant. The host whose
          `krg.tenantPlatform.id` equals this value runs the tenant's microVM;
          others leave it inert.
        '';
      };

      repo = lib.mkOption {
        type = lib.types.str;
        example = "UCSD-E4E/fishsense-lite";
        description = ''
          The GitHub `owner/repo` that owns this tenant's deployment. The in-VM
          self-hosted runner registers to exactly this repo (repo-scoped, never
          org-scoped) — it is both the deploy binding and the security boundary.
        '';
      };

      subtree = lib.mkOption {
        type = lib.types.str;
        example = "fishsense.e4e.ucsd.edu";
        description = ''
          The subdomain subtree this tenant owns. The edge routes the apex AND
          every name beneath it to this VM — rule `^(.+\.)?<subtree>$` — so e.g.
          both `fishsense.e4e.ucsd.edu` (apex) and `orchestrator.fishsense.…`
          land here. New names under the subtree need no edge change.
        '';
      };

      hostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["fishsense.e4e.ucsd.edu" "orchestrator.fishsense.e4e.ucsd.edu"];
        description = ''
          The EXPLICIT hostname list for the edge's Let's Encrypt issuance (one
          multi-SAN cert per tenant, HTTP-01 — wildcards/DNS-01 are not available).
          On-demand TLS is forbidden, so every public name must be listed here
          (ADR 0008 issuance invariant). Routing is by `subtree`; this is purely
          the cert SAN set.
        '';
      };

      deployDir = lib.mkOption {
        type = lib.types.str;
        default = "/srv/${name}";
        description = "Persistent in-VM checkout the runner deploys from (`DEPLOY_DIR`).";
      };

      resources = {
        vcpu = lib.mkOption {
          type = lib.types.ints.positive;
          default = 2;
          description = "vCPUs for the tenant microVM.";
        };
        memMiB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 4096;
          description = "RAM (MiB) for the tenant microVM.";
        };
        diskGiB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 50;
          description = "Size (GiB) of the tenant's durable ZFS zvol (DEPLOY_DIR + Postgres).";
        };
      };

      isolation = lib.mkOption {
        type = lib.types.enum ["microvm"];
        default = "microvm";
        description = ''
          Isolation backend. `microvm` (the default and only value today) runs the
          tenant as a sealed cloud-hypervisor guest. A pluggable knob so a tenant
          can be moved to a stronger boundary later without reshaping the platform.
        '';
      };

      secrets.openbaoPath = lib.mkOption {
        type = lib.types.str;
        example = "secret/e4e-student/fishsense";
        description = ''
          The tenant's OpenBao KV path. Its per-tenant AppRole is scoped here; the
          in-VM vault-agent renders the app's secrets into `deployDir` from it.
        '';
      };
    };
  };
in {
  # The microvm.nix host module — defines `microvm.host.*` and the guest runner
  # services. Imported unconditionally (imports can't be config-gated) but inert
  # until `microvm.host.enable` below flips with the platform.
  imports = [inputs.microvm.nixosModules.host];

  options.krg.tenantPlatform = {
    enable = lib.mkEnableOption "the student-project tenant platform (one sealed microVM per tenant)";

    id = lib.mkOption {
      type = lib.types.str;
      example = "e4e-student";
      description = ''
        This platform instance's id. The host runs exactly the `krg.tenants` whose
        `platform` equals this. Lets two platform hosts (e.g. `e4e-student` and
        `krg-student`) share one roster, partitioned by this field.
      '';
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "vmbr-tenants";
      description = ''
        Host bridge the tenant microVM TAP interfaces attach to (a private
        RFC1918 segment behind the edge — tenants never get public addresses).
      '';
    };
  };

  options.krg.tenants = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule tenantModule);
    default = {};
    description = ''
      The shared tenant roster (org-wide, not host-specific). Imported by every
      platform host; each host instantiates only the entries whose `platform`
      matches its `krg.tenantPlatform.id`.
    '';
  };

  config = lib.mkMerge [
    # The microvm.nix host module defaults `enable` to true once imported, so force
    # it to FOLLOW the platform toggle — otherwise importing this module would turn
    # on the host's microVM machinery everywhere it's available.
    {microvm.host.enable = cfg.enable;}

    (lib.mkIf cfg.enable {
      assertions =
        [
          {
            assertion = cfg.id != "";
            message = "krg.tenantPlatform.id must be set (the platform instance id tenants are matched against).";
          }
        ]
        ++ lib.mapAttrsToList (name: t: {
          assertion = t.hostnames != [];
          message = "krg.tenants.${name}.hostnames must be non-empty — the edge issues LE certs only from an explicit SAN list (no on-demand TLS, ADR 0008).";
        })
        myTenants;

      # Surface which tenants this host owns; the microVM generator (follow-up) maps
      # `myTenants` into `microvm.vms.<name>`.
      warnings = lib.optional (myTenants == {}) "krg.tenantPlatform is enabled (id=${cfg.id}) but no krg.tenants have platform=\"${cfg.id}\" — the platform will run only the edge, no tenant VMs.";
    })
  ];
}
