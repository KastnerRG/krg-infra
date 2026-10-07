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
#
# TWO PROVIDERS, ONE ROUTE SET. e4e-prod runs this edge as a NATIVE Traefik
# (`provider = "native"`, the default). krg-prod already runs a compose Traefik that
# fronts the lab-wide services and owns :80/:443 plus its LE account, so a second
# Traefik can't bind there. It uses `provider = "file"` instead: the SAME routers/
# services/transports are rendered to `dynamicConfigFile`, which krg-prod mounts into
# its compose Traefik as a file provider. Same issuance invariant, same re-encrypt
# verification (the container can't see the host trust store, so `rootCAs` names the
# fleet CA).
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.edge;
  # Escape a hostname's dots for the Go HostRegexp (matches the apex + all descendants).
  escapeDots = s: replaceStrings ["."] ["\\."] s;
  reencryptRoutes = filterAttrs (_: r: r.reencrypt) cfg.routes;

  # Per route: a router (apex + descendants of the subtree), a service pointing at
  # the backend (over the re-encrypt transport when reencrypt=true), and — for
  # re-encrypt routes — a transport that verifies the backend's cert by serverName.
  # Shared by both providers (native: services.traefik; file: dynamicConfigFile).
  dynamicHttp = {
    routers =
      mapAttrs' (
        name: r:
          nameValuePair "edge-${name}" {
            rule = "HostRegexp(`^(.+\\.)?${escapeDots r.subtree}$`)";
            entryPoints = ["websecure"];
            service = "edge-${name}";
            tls = {
              inherit (cfg) certResolver;
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
          nameValuePair "edge-${name}" (
            {
              inherit (r) serverName; # verify the backend's tenant-internal cert vs the fleet CA
            }
            // optionalAttrs (cfg.rootCAs != []) {inherit (cfg) rootCAs;}
          )
      )
      reencryptRoutes;
  };
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

    provider = mkOption {
      type = types.enum ["native" "file"];
      default = "native";
      description = ''
        How the routes reach a Traefik. "native": run services.traefik on this host (it
        owns :80/:443 and the ACME account; e4e-prod). "file": render the routes to
        `dynamicConfigFile` ONLY, for a Traefik this host already runs another way
        (krg-prod's compose Traefik) to load as a file provider. In "file" mode `acme.*`
        is inert: issuance uses that Traefik's resolver, named by `certResolver`.
      '';
    };

    certResolver = mkOption {
      type = types.str;
      default = "le";
      description = ''
        The ACME resolver each route's router issues from. "le" is the one the native
        provider defines; in "file" mode it MUST name a resolver the host's Traefik
        already defines (krg-prod: "letsencrypt").
      '';
    };

    rootCAs = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["/etc/traefik/edge/krg-pki-ca.pem"];
      description = ''
        CA files (paths as the TRAEFIK PROCESS sees them) a re-encrypt transport
        verifies the backend's tenant-internal cert against. Empty = Traefik's system
        trust store, which on a native edge already holds the fleet CA (base.nix
        security.pki). A containerised Traefik can't see that store, so in "file" mode
        mount the fleet CA in and name it here.
      '';
    };

    dynamicConfigFile = mkOption {
      type = types.path;
      readOnly = true;
      description = ''
        The routes rendered as a Traefik dynamic (file-provider) config. Mounted by
        `provider = "file"` hosts; computed either way.
      '';
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

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = all (r: r.hostnames != []) (attrValues cfg.routes);
          message = "krg.edge: every route needs a non-empty `hostnames` list — the edge issues LE certs only from an explicit SAN list (no on-demand TLS, ADR 0017 §5).";
        }
      ];

      # Rendered for both providers; only "file" hosts mount it. JSON is valid YAML,
      # so Traefik's file provider reads it by the .yml extension. Empty sections are
      # DROPPED: the file provider rejects an empty `routers: {}` ("routers cannot be a
      # standalone element") and discards the whole file, so an edge with no routes
      # yet renders `{}`, which loads cleanly (checked against traefik:v3.7).
      krg.edge.dynamicConfigFile = let
        http = filterAttrs (_: v: v != {}) dynamicHttp;
      in
        pkgs.writeText "krg-edge-${cfg.zone}.yml" (builtins.toJSON (optionalAttrs (http != {}) {inherit http;}));
    }

    (mkIf (cfg.provider == "native") {
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

        dynamicConfigOptions.http = dynamicHttp;
      };

      # :80 world-open for ACME HTTP-01 — LE validates from many source IPs, so it must
      # NEVER be source-restricted. :443 is opened by the host's server-profile
      # allowedTCPPorts. acme.json under /var/lib/traefik MUST survive reboots (re-issuing
      # each boot would burn the rate limit); when impermanence lands on the edge host,
      # add it to the /persist set.
      krg.firewall.publicPorts = [80]; # reason: ACME HTTP-01 (LE multi-perspective validators are global)
    })
  ]);
}
