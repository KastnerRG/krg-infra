# krg.edge — a per-DNS-zone public edge (ADR 0017 §5). Re-homes the retired #371
# microvm-edge logic onto the Incus platform: one Traefik that terminates public TLS
# (the SOLE Let's Encrypt client for its zone) and RE-ENCRYPTS to internal Incus
# backends over the lab OpenBao PKI (ADR 0009) — or plain on the trusted internal
# segment (opt-in per route).
#
# WHY PER ZONE (ADR 0017 §5): UCSD DNS gives specific CNAMEs only — no wildcards, and
# only to public IPs — so a `*.krg.ucsd.edu` name can only point at krg-prod's IP and a
# `*.e4e.ucsd.edu` name at e4e-prod's. Two zones ⇒ two edges ⇒ independent ACME accounts
# / cert budgets / blast radii. This module is that edge; e4e-prod enables it for the
# e4e zone.
#
# THE ISSUANCE INVARIANT (ADR 0017 §5, ADR 0008): issuance is driven ONLY by the
# explicit per-route `tls.domains` SAN list (HTTP-01 per name). On-demand / catch-all
# TLS is NEVER enabled, so a stranger SNI can't trigger a (failing) issuance and burn
# the shared `ucsd.edu` rate-limit budget. A route therefore exists ONLY once its CNAME
# does — `routes` is empty by default and each addition is an admin act (§6).
#
# RE-ENCRYPT: the backend (the tenant's inner Traefik on its Incus instance) serves a
# `tenant-internal` cert (terraform/openbao pki.tf — minted by the tenant's own AppRole,
# #374); the edge verifies it by `serverName` against the fleet CA in the system trust
# store (base.nix security.pki). A leaf rotating on the backend never trips cert-TOFU
# because validation is by chain.
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.krg.edge;
  # Escape a hostname's dots for the Go HostRegexp (matches the apex + all descendants).
  escapeDots = s: replaceStrings ["."] ["\\."] s;
  reencryptRoutes = filterAttrs (_: r: r.reencrypt) cfg.routes;
in {
  options.krg.edge = {
    enable = mkEnableOption "KRG per-zone public edge (Traefik LE-terminate → re-encrypt)";

    zone = mkOption {
      type = types.str;
      example = "e4e";
      description = "DNS-zone label this edge fronts (krg | e4e). Informational; the route hostnames are authoritative.";
    };

    acme = {
      email = mkOption {
        type = types.str;
        default = "shperry@ucsd.edu";
        description = "Let's Encrypt account email — this edge is the SOLE ACME client for its zone.";
      };
      staging = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use the LE STAGING directory (untrusted certs, generous limits). Flip ON when
          adding the FIRST real route to validate the HTTP-01 path without burning the
          shared `ucsd.edu` prod rate-limit budget, then back OFF (ADR 0017 §5 / ADR 0008
          staging-first).
        '';
      };
    };

    routes = mkOption {
      default = {};
      description = ''
        Per-name public routes. EMPTY by default — the edge stands up with entrypoints +
        the ACME resolver but NO routers, so it issues no certs until a route (and its
        CNAME) exists (the issuance invariant + the per-name admin gate, ADR 0017 §5/§6).
      '';
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          subtree = mkOption {
            type = types.str;
            example = "fishsense.e4e.ucsd.edu";
            description = "Routes the apex AND every name beneath it (`^(.+\\.)?<subtree>$`) to this backend.";
          };
          hostnames = mkOption {
            type = types.listOf types.str;
            example = ["fishsense.e4e.ucsd.edu" "api.fishsense.e4e.ucsd.edu"];
            description = ''
              The EXPLICIT LE SAN list (one multi-SAN cert per route, HTTP-01). Every
              public name must be listed — on-demand TLS is forbidden (issuance invariant).
            '';
          };
          backend = mkOption {
            type = types.str;
            example = "10.100.0.21:443";
            description = ''
              The internal address the edge dials — the tenant's Incus instance on the NAT,
              reached via the bring-up ingress path (route / proxy / shared bridge; see the
              krg-nat host config). host:port.
            '';
          };
          serverName = mkOption {
            type = types.str;
            default = "${name}.vm";
            description = ''
              Re-encrypt: the cert SAN to verify on the backend — the tenant-internal cert
              (terraform/openbao pki.tf, `*.vm`), validated against the fleet CA in the
              system trust store. Inert when reencrypt = false.
            '';
          };
          reencrypt = mkOption {
            type = types.bool;
            default = true;
            description = ''
              https + verify to the backend (re-encrypt over the lab PKI). false = plain
              http to a backend on the trusted internal segment (ADR 0017 §5 opt-in).
            '';
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = all (r: r.hostnames != []) (attrValues cfg.routes);
        message = "krg.edge: every route needs a non-empty `hostnames` list — the edge issues LE certs only from an explicit SAN list (no on-demand TLS, ADR 0017 §5).";
      }
    ];

    services.traefik = {
      enable = true;

      staticConfigOptions = {
        entryPoints = {
          # :80 — ACME HTTP-01 challenge + redirect everything else to https.
          web = {
            address = ":80";
            http.redirections.entryPoint = {
              to = "websecure";
              scheme = "https";
            };
          };
          websecure.address = ":443";
        };
        certificatesResolvers.le.acme =
          {
            email = cfg.acme.email;
            storage = "/var/lib/traefik/acme.json"; # MUST persist (don't re-issue each boot)
            httpChallenge.entryPoint = "web";
          }
          // optionalAttrs cfg.acme.staging {
            caServer = "https://acme-staging-v02.api.letsencrypt.org/directory";
          };
      };

      # Per route: a router (apex + descendants of the subtree), a service pointing at
      # the backend (over the re-encrypt transport when reencrypt=true), and — for
      # re-encrypt routes — a transport that verifies the backend's cert by serverName.
      dynamicConfigOptions.http = {
        routers =
          mapAttrs' (
            name: r:
              nameValuePair "edge-${name}" {
                rule = "HostRegexp(`^(.+\\.)?${escapeDots r.subtree}$`)";
                entryPoints = ["websecure"];
                service = "edge-${name}";
                tls = {
                  certResolver = "le";
                  # Explicit multi-SAN issuance (NOT on-demand) — the invariant.
                  domains = [
                    {
                      main = head r.hostnames;
                      sans = tail r.hostnames;
                    }
                  ];
                };
              }
          )
          cfg.routes;

        services =
          mapAttrs' (
            name: r:
              nameValuePair "edge-${name}" {
                loadBalancer =
                  {
                    servers = [
                      {
                        url = "${
                          if r.reencrypt
                          then "https"
                          else "http"
                        }://${r.backend}";
                      }
                    ];
                  }
                  // optionalAttrs r.reencrypt {
                    serversTransport = "edge-${name}";
                  };
              }
          )
          cfg.routes;

        serversTransports =
          mapAttrs' (
            name: r:
              nameValuePair "edge-${name}" {
                inherit (r) serverName; # verify the backend's tenant-internal cert vs the fleet CA
              }
          )
          reencryptRoutes;
      };
    };

    # :80 world-open for ACME HTTP-01 — LE validates from many source IPs, so it must
    # NEVER be source-restricted. :443 is opened by the host's server-profile
    # allowedTCPPorts. acme.json under /var/lib/traefik MUST survive reboots (re-issuing
    # each boot would burn the rate limit); when impermanence lands on the edge host,
    # add it to the /persist set.
    krg.firewall.publicPorts = [80]; # reason: ACME HTTP-01 (LE multi-perspective validators are global)
  };
}
