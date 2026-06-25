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
# host, each on a dedicated ZFS dataset — so a compromised/careless deploy is
# confined to its own VM (runner-root = root of that VM, not the host). `isolation`
# is a pluggable knob (`microvm` today) so a tenant can later be moved to a
# stronger boundary without a rewrite.
#
# STATUS: this commit adds the per-tenant microVM GENERATOR — a bootable sealed
# guest (cloud-hypervisor, a private bridged network, Docker, a durable per-tenant
# ZFS-backed disk, break-glass SSH via the platform admin keys). Still to come
# (gated on the GitHub App + the per-tenant OpenBao AppRoles): the in-VM
# self-hosted runner, vault-agent + PKI certs, the inner Traefik + Authentik
# outpost, guest impermanence, and the platform EDGE (terminate LE → re-encrypt).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  inherit (lib) types mkOption mkEnableOption mkIf mkMerge mkForce mapAttrs mapAttrs' mapAttrsToList nameValuePair filterAttrs optional;

  cfg = config.krg.tenantPlatform;
  net = cfg.network;

  # Tenants assigned to THIS platform instance (platform == our id). Hosts ignore
  # tenants belonging to a sibling platform, so the same roster is importable
  # everywhere.
  myTenants = filterAttrs (_: t: t.platform == cfg.id) config.krg.tenants;

  # ── deterministic per-tenant addressing (from the explicit network.id) ──────
  # MAC: locally-administered (02:…), last byte = the tenant id, so it's stable
  # across reboots/redeploys and maps 1:1 to the bridge IP. IP: <prefix>.<id>.
  hexChars = lib.stringToCharacters "0123456789abcdef";
  mod = a: b: a - (b * (a / b));
  toHex2 = n: "${builtins.elemAt hexChars (n / 16)}${builtins.elemAt hexChars (mod n 16)}";
  tenantMac = id: "02:00:00:00:00:${toHex2 id}";
  tenantIp = id: "${net.prefix}.${toString id}";
  gatewayIp = "${net.prefix}.1";

  # Platform-ops break-glass SSH keys for the tenant VMs = the host's admin account
  # keys (e.g. e4e-admin; includes the krg-deploy key). Read on the host and embedded
  # into the guest eval (the guest is a separate NixOS evaluation).
  adminKeys = (builtins.fromJSON (builtins.readFile ../keys/admins.json)).${config.krg.adminAccount} or [];

  # The guest NixOS config for one tenant — a sealed, bridged, Docker-capable box.
  genGuest = name: t: {
    system.stateVersion = config.system.stateVersion;

    microvm = {
      hypervisor = "cloud-hypervisor";
      vcpu = t.resources.vcpu;
      mem = t.resources.memMiB;

      # vsock for clean systemd-notify startup (cid unique per host = the tenant id).
      vsock.cid = t.network.id;

      # cloud-hypervisor supports only "tap" interfaces; microvm creates the tap
      # `vm-<name>`. It's enslaved to cfg.bridge host-side by a udev rule (below) —
      # the "bridge" interface type is QEMU-only.
      interfaces = [
        {
          type = "tap";
          id = "vm-${name}";
          mac = tenantMac t.network.id;
        }
      ];

      # Durable disk — a raw image on the per-tenant ZFS dataset (quota + snapshots
      # live on the dataset). Holds DEPLOY_DIR + the project's Postgres etc.
      volumes = [
        {
          image = "/var/lib/tenants/${name}/data.img";
          size = t.resources.diskGiB * 1024; # MiB
          mountPoint = "/var/lib/state";
          fsType = "ext4";
          autoCreate = true;
        }
      ];
    };

    # Static IP on the private bridge subnet, matched by MAC (the guest interface
    # name is hypervisor-dependent; the MAC is stable). NAT on the host gives the
    # VM upstream reachability (image pulls, GitHub, OpenBao, krg-prod Temporal).
    networking = {
      useNetworkd = true;
      useDHCP = false;
      nameservers = net.nameservers;
      firewall.allowedTCPPorts = [22];
    };
    systemd.network.networks."10-tenant" = {
      matchConfig.MACAddress = tenantMac t.network.id;
      address = ["${tenantIp t.network.id}/24"];
      routes = [{Gateway = gatewayIp;}];
    };

    virtualisation.docker.enable = true;

    # Break-glass only: key-only SSH, bridge-reachable (never external), authorized
    # for the platform-ops keys. Tenant maintainers get NO shell — they deploy via
    # their repo and observe via Grafana/Loki (ADR 0008 operator-access model).
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    users.mutableUsers = false;
    users.users.ops = {
      isNormalUser = true;
      extraGroups = ["wheel" "docker"];
      openssh.authorizedKeys.keys = adminKeys;
    };
    security.sudo.wheelNeedsPassword = false;
  };
in {
  # The microvm.nix host module — defines `microvm.host.*` and the guest runner
  # services. Imported unconditionally (imports can't be config-gated) but inert
  # until `microvm.host.enable` below flips with the platform.
  imports = [inputs.microvm.nixosModules.host];

  options.krg.tenantPlatform = {
    enable = mkEnableOption "the student-project tenant platform (one sealed microVM per tenant)";

    id = mkOption {
      type = types.str;
      example = "e4e-student";
      description = ''
        This platform instance's id. The host runs exactly the `krg.tenants` whose
        `platform` equals this. Lets two platform hosts (e.g. `e4e-student` and
        `krg-student`) share one roster, partitioned by this field.
      '';
    };

    bridge = mkOption {
      type = types.str;
      default = "vmbr-tenants";
      description = "Host bridge the tenant microVM TAP interfaces attach to.";
    };

    uplink = mkOption {
      type = types.str;
      default = "ens18";
      description = "Host uplink interface NAT'd for tenant-VM egress.";
    };

    network = {
      prefix = mkOption {
        type = types.str;
        default = "10.73.0";
        description = ''
          The /24 prefix of the private tenant bridge subnet. The host is
          `<prefix>.1`; each tenant is `<prefix>.<network.id>`. Tenants never get
          public addresses — the edge fronts them.
        '';
      };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = ["132.239.0.252" "8.8.8.8"];
        description = "Resolvers the tenant VMs use (via the host NAT).";
      };
    };
  };

  options.krg.tenants = mkOption {
    default = {};
    description = ''
      The shared tenant roster (org-wide, not host-specific). Imported by every
      platform host; each host instantiates only the entries whose `platform`
      matches its `krg.tenantPlatform.id`.
    '';
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        platform = mkOption {
          type = types.str;
          example = "e4e-student";
          description = "Which platform instance hosts this tenant (matched against `krg.tenantPlatform.id`).";
        };

        repo = mkOption {
          type = types.str;
          example = "UCSD-E4E/fishsense-lite";
          description = ''
            The GitHub `owner/repo` that owns this tenant's deployment. The in-VM
            self-hosted runner registers to exactly this repo (repo-scoped, never
            org-scoped) — both the deploy binding and the security boundary.
          '';
        };

        subtree = mkOption {
          type = types.str;
          example = "fishsense.e4e.ucsd.edu";
          description = ''
            The subdomain subtree this tenant owns. The edge routes the apex AND
            every name beneath it to this VM (`^(.+\.)?<subtree>$`).
          '';
        };

        hostnames = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["fishsense.e4e.ucsd.edu" "orchestrator.fishsense.e4e.ucsd.edu"];
          description = ''
            The EXPLICIT hostname list for the edge's Let's Encrypt issuance (one
            multi-SAN cert per tenant, HTTP-01). On-demand TLS is forbidden, so
            every public name must be listed (ADR 0008 issuance invariant).
          '';
        };

        deployDir = mkOption {
          type = types.str;
          default = "/srv/${name}";
          description = "Persistent in-VM checkout the runner deploys from (`DEPLOY_DIR`).";
        };

        resources = {
          vcpu = mkOption {
            type = types.ints.positive;
            default = 2;
            description = "vCPUs for the tenant microVM.";
          };
          memMiB = mkOption {
            type = types.ints.positive;
            default = 4096;
            description = "RAM (MiB) for the tenant microVM.";
          };
          diskGiB = mkOption {
            type = types.ints.positive;
            default = 50;
            description = "Size (GiB) of the tenant's durable disk (ZFS dataset quota).";
          };
        };

        network.id = mkOption {
          type = types.ints.between 2 254;
          example = 10;
          description = ''
            Stable per-tenant host id on the bridge subnet (like a VMID). Drives the
            tenant's IP (`<prefix>.<id>`) and MAC (`02:00:00:00:00:<id>`). Must be
            unique among the tenants on a platform (asserted).
          '';
        };

        isolation = mkOption {
          type = types.enum ["microvm"];
          default = "microvm";
          description = "Isolation backend (a pluggable knob; `microvm` today).";
        };

        secrets.openbaoPath = mkOption {
          type = types.str;
          example = "secret/e4e-student/fishsense";
          description = "The tenant's OpenBao KV path (its AppRole is scoped here).";
        };
      };
    }));
  };

  config = mkMerge [
    # The microvm.nix host module defaults `enable` to true once imported, so force
    # it to FOLLOW the platform toggle — otherwise importing this module would turn
    # on the host's microVM machinery everywhere it's available.
    {microvm.host.enable = cfg.enable;}

    (mkIf cfg.enable {
      assertions =
        [
          {
            assertion = cfg.id != "";
            message = "krg.tenantPlatform.id must be set (the platform instance id tenants are matched against).";
          }
          {
            assertion = let ids = mapAttrsToList (_: t: t.network.id) myTenants; in lib.length ids == lib.length (lib.unique ids);
            message = "krg.tenants network.id values must be unique among the tenants on platform \"${cfg.id}\" (they map to bridge IP/MAC).";
          }
        ]
        ++ mapAttrsToList (name: t: {
          assertion = t.hostnames != [];
          message = "krg.tenants.${name}.hostnames must be non-empty — the edge issues LE certs only from an explicit SAN list (no on-demand TLS, ADR 0008).";
        })
        myTenants;

      warnings = optional (myTenants == {}) "krg.tenantPlatform is enabled (id=${cfg.id}) but no krg.tenants have platform=\"${cfg.id}\" — the platform will run only the edge, no tenant VMs.";

      # ── private tenant bridge + NAT egress ────────────────────────────────────
      networking.bridges.${cfg.bridge}.interfaces = []; # taps enslaved via udev below
      networking.interfaces.${cfg.bridge}.ipv4.addresses = [
        {
          address = gatewayIp;
          prefixLength = 24;
        }
      ];

      # Enslave each microVM tap (`vm-<name>`) to the bridge as it's created. A udev
      # rule (not host networkd) so it works with the scripted host networking and
      # re-fires every time microvm recreates the tap on VM (re)start.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="net", KERNEL=="vm-*", RUN+="${lib.getExe' pkgs.iproute2 "ip"} link set %k master ${cfg.bridge}"
      '';
      networking.nat = {
        enable = true;
        internalInterfaces = [cfg.bridge];
        externalInterface = cfg.uplink;
      };

      # Host-side /etc/hosts: `<tenant>.vm` -> its bridge IP (operator break-glass:
      # `ssh -J e4e-admin@e4e-prod ops@<tenant>.vm`).
      networking.hosts = mapAttrs' (name: t: nameValuePair (tenantIp t.network.id) ["${name}.vm"]) myTenants;

      systemd.tmpfiles.rules = ["d /var/lib/tenants 0755 root root -"];

      # Per-tenant durable ZFS dataset (quota'd), provisioned before its microVM
      # starts. disko made the `rpool/tenants` container; children are created here
      # because tenants are added over time, not at install.
      systemd.services = mapAttrs' (name: t:
        nameValuePair "tenant-dataset-${name}" {
          description = "Provision the ZFS dataset for tenant ${name}";
          wantedBy = ["microvms.target"];
          before = ["microvm@${name}.service"];
          requiredBy = ["microvm@${name}.service"];
          after = ["zfs.target"];
          path = [pkgs.zfs];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ds=rpool/tenants/${name}
            if ! zfs list "$ds" >/dev/null 2>&1; then
              zfs create -o mountpoint=/var/lib/tenants/${name} -o quota=${toString t.resources.diskGiB}G "$ds"
            else
              zfs set quota=${toString t.resources.diskGiB}G "$ds"
            fi
          '';
        })
      myTenants;

      # ── the tenant microVMs ───────────────────────────────────────────────────
      microvm.vms =
        mapAttrs (name: t: {
          config = genGuest name t;
          specialArgs = {inherit inputs;};
          autostart = true;
        })
        myTenants;
    })
  ];
}
