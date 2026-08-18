# lib.mkTenant — the versioned, tenant-facing deploy contract (ADR 0020).
#
# A tenant repo pins krg-infra and calls this to declare its deploy target. The
# function is PURE and SECRET-FREE on purpose (ADR 0020 §1/§5): a tenant must be able
# to evaluate it without dragging in host configs or fabricant's secrets. It validates
# + normalizes the request and returns a structured spec whose fields encode the
# load-bearing trust split (ADR 0017 §2, ADR 0020 §3):
#
#   • interior  — TENANT-OWNED, authoritative: compose / image / deploy cadence.
#   • boundary  — REQUESTS, admin-provisioned (never self-granted): hostname/CNAME,
#                 edge zone/route, sso.group, resource quota, the OpenBao KV prefix.
#
# The declaration is a SPEC, not a grant. An admin provisions the boundary via
# terraform/incus — so the spec also exposes `terraformTenant`, the EXACT shape that
# root module's `var.tenants` expects, making spec→provision mechanical (a reviewed PR
# copies it in; a tenant cannot self-grant).
#
# Stability: this signature IS the contract. Tenants pin a krg-infra rev (ADR 0020 §5),
# so a breaking change here is an explicit bump on their side — keep it narrow.
{lib}: {
  # ── identity ──────────────────────────────────────────────────────────────────
  name, # tenant slug (Incus project, OpenBao role, runner scope)
  # ── boundary (requests) ───────────────────────────────────────────────────────
  zone, # "krg" | "e4e" — which public edge routes to it
  hostname, # requested public FQDN (the CNAME the admin files)
  sso ? {}, # { group ? name } — AD group gating access at the edge
  resources ? {}, # { cpu ? 2; ram ? "4GiB"; disk ? "20GiB"; }
  isolation ? "virtual-machine", # "virtual-machine" (untrusted/developed) | "container"
  temporal ? null, # { namespace, reload ? [] } — request a krg-prod Temporal client cert (ADR 0023). null = none.
  # ── interior (tenant-owned) ───────────────────────────────────────────────────
  compose ? null, # path to the tenant's compose file (repo-owns-deploy)
  image ? "", # golden-template image for the slot; "" = boundary only (no instance yet)
  repo ? null, # tenant repo (github owner/name) the runner is scoped to; informational here
}: let
  # Defaults applied once, here, so the spec is fully normalized for every consumer.
  cpu = resources.cpu or 2;
  ram = resources.ram or "4GiB";
  disk = resources.disk or "20GiB";
  ssoGroup = sso.group or name;

  # Typed-contract validation — fail evaluation loudly on a malformed declaration
  # (this is what "typed realization of repo-owns-deploy" means). Each check throws a
  # tenant-actionable message keyed by name.
  ctx = "mkTenant(${name})";
  nameOk = builtins.match "[a-z][a-z0-9-]*" name != null;
  validated =
    lib.throwIf (!nameOk)
    "${ctx}: name must be a lowercase slug [a-z][a-z0-9-]* (Incus project + OpenBao role name)"
    (lib.throwIf (!builtins.elem zone ["krg" "e4e"])
      "${ctx}: zone must be \"krg\" or \"e4e\" (selects the public edge)"
      (lib.throwIf (!builtins.elem isolation ["virtual-machine" "container"])
        "${ctx}: isolation must be \"virtual-machine\" or \"container\" (ADR 0017 §4: untrusted = VM)"
        (lib.throwIf (!lib.isString hostname || hostname == "")
          "${ctx}: hostname (requested public FQDN) is required"
          null)));
in
  # Force the validation chain before returning (seq makes the throws fire on access).
  builtins.seq validated {
    inherit name zone hostname;

    # TENANT-OWNED interior — authoritative, shipped by the tenant's runner.
    interior = {
      inherit compose image repo;
    };

    # ADMIN-PROVISIONED boundary — requests. Mirrors terraform/openbao/tenants.tf's
    # per-tenant KV prefix so the OpenBao AppRole + the Incus project line up by name.
    boundary = {
      inherit hostname zone isolation;
      sso = {group = ssoGroup;};
      resources = {inherit cpu ram disk;};
      kvPrefix = "tenants/${name}"; # OpenBao secret/<kvPrefix>/* (per-tenant policy)
      # Temporal access request (ADR 0023). null = none; otherwise the admin grants
      # pki_int/issue/temporal-client on the tenant policy + confirms the namespace, and
      # nixosModules.tenant renders the client cert to /run/tenant/temporal/. The worker
      # cert CN is "<name>-worker".
      #
      # `reload` is the tenant-owned half of cert ROTATION: the platform re-renders the
      # leaf before it expires (krg.vaultAgent.renewal), but a worker that builds its TLS
      # config once at Client.connect keeps the OLD cert for the life of the process, so
      # a fresh file on /run recovers nothing by itself. This lists the compose SERVICE
      # names to restart when the cert rotates. Only the tenant knows which of its
      # services dial Temporal, hence a request field rather than a platform guess.
      # EMPTY = restart the whole interior stack: correct but blunt (it bounces the
      # tenant's web path too), so name the worker service(s) to narrow it.
      temporal =
        if temporal == null
        then null
        else {
          inherit (temporal) namespace;
          reload = temporal.reload or [];
        };
    };

    # Admin-side spec→provision projection: the EXACT object terraform/incus's
    # `var.tenants` map value expects (zone/cpu/memory/disk/isolation/image). An admin
    # reviewing the tenant's PR copies `terraformTenant` into terraform/incus — no
    # translation, no self-grant. `memory` is `ram` renamed to the Incus field name.
    terraformTenant = {
      inherit zone isolation image cpu disk;
      memory = ram; # `ram` renamed to the Incus field name
    };
  }
