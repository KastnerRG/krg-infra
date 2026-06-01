{ ... }:
let
  trusted = builtins.fromJSON (builtins.readFile ../../networks/trusted.json);
in {
  imports = [
    ../../profiles/base.nix
    ../../modules/users.nix
    ../../users/admin.nix
    ./hardware-configuration.nix
  ];

  krg.adminAccount = "krg-admin";

  krg.base = {
    enable      = true;
    autoUpgrade = true;
    serviceHost = true;
    isVM        = true;
  };

  networking = {
    hostName = "krg-vault";
    domain   = "ucsd.edu";
    useDHCP  = false;
    interfaces.ens18.ipv4.addresses = [{
      address      = "137.110.161.123";
      prefixLength = 24;
    }];
    defaultGateway = "137.110.161.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];
  };

  # Not yet domain-joined — disable AD client until keytab is provisioned.
  krg.adClient.enable = false;

  # Ensure the bao CLI always talks to the local instance over TLS.
  # Without this it defaults to https://127.0.0.1:8200 which fails cert
  # validation (the Let's Encrypt cert covers the hostname, not the IP).
  environment.variables.VAULT_ADDR = "https://krg-vault.ucsd.edu:8200";

  krg.firewall = {
    # SSH (22) inherits from base.nix's default allowedTCPPorts = [22];
    # serviceHost = true (also from base.nix default) restricts it to
    # ucsd + ops via sshSources (stricter than the fleet CrowdSec floor).
    monitoringPorts = [ 9100 ];
    # 80 → globally public for ACME HTTP-01 ONLY. Let's Encrypt does
    # multi-perspective validation from US + EU + Asia validators with
    # unpredictable source IPs; ANY source restriction (geo allowlist,
    # behavioral ban, even an accidental community-blocklist hit on an
    # LE infrastructure IP) would risk breaking cert issuance/renewal.
    # nginx serves only the /.well-known/acme-challenge/ path on 80;
    # everything else 404s — small attack surface. DNS-01 migration to
    # close this entirely was considered but is out of scope (would need
    # RFC2136 / acme-dns infra) — see closed issue #89 for the analysis.
    publicPorts = [ 80 ];  # reason: ACME HTTP-01 (LE multi-perspective)
    # 8200: OpenBao API — sealab + ops + machines only, matching the
    # Proxmox perimeter. Strictly tighter than the fleet CrowdSec default;
    # sourcedPorts always takes precedence over the globally-open list, so
    # 8200 doesn't double-gate.
    sourcedPorts = [{
      port    = 8200;
      sources = map (e: e.cidr) trusted.ipsets.sealab
             ++ map (e: e.cidr) trusted.ipsets.ops
             ++ map (e: e.cidr) trusted.ipsets.machines;
    }];
  };

  # Let's Encrypt cert for krg-vault.ucsd.edu.
  # nginx serves the HTTP-01 ACME challenge on port 80; OpenBao reads the
  # resulting cert files. On renewal, openbao gets a SIGHUP to reload the cert.
  security.acme = {
    acceptTerms = true;
    defaults.email = "shperry@ucsd.edu";
    certs."krg-vault.ucsd.edu" = {
      group   = "nginx";   # nginx reads it for ACME; openbao added below
      postRun = "systemctl reload openbao.service || true";
    };
  };

  # Give openbao read access to the cert files (group nginx owns them).
  systemd.services.openbao.serviceConfig.SupplementaryGroups = [ "nginx" ];

  services.nginx = {
    enable = true;
    # Minimal vhost — serves only the ACME challenge, no other content.
    virtualHosts."krg-vault.ucsd.edu" = {
      enableACME = true;
      forceSSL   = false;
    };
  };

  services.openbao = {
    enable = true;
    settings = {
      ui = true;

      listener.default = {
        type          = "tcp";
        address       = "0.0.0.0:8200";
        tls_cert_file = "/var/lib/acme/krg-vault.ucsd.edu/cert.pem";
        tls_key_file  = "/var/lib/acme/krg-vault.ucsd.edu/key.pem";
      };

      storage.raft = {
        path    = "/var/lib/openbao";
        node_id = "krg-vault-1";
      };

      api_addr     = "https://krg-vault.ucsd.edu:8200";
      cluster_addr = "https://krg-vault.ucsd.edu:8201";
    };
  };

  system.stateVersion = "25.11";
}
