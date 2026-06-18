{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.xrdp;
  tls = cfg.tlsCert;

  # consul-template args for the single pki_int/issue/host call. ip_sans is included
  # only when set (the Guacamole gateway typically dials the box by IP, so that SAN is
  # what the RDP client verifies).
  certSecretArgs = concatStringsSep " " (
    [''"common_name=${tls.commonName}"'']
    ++ optional (tls.ipSans != []) ''"ip_sans=${concatStringsSep "," tls.ipSans}"''
    ++ [''"ttl=720h"'']
  );
in {
  imports = [
    ../users.nix
    ../services/vault-agent.nix # krg.xrdp.tlsCert renders the cert via krg.vaultAgent
  ];

  options.krg.xrdp = {
    enable = mkEnableOption "XRDP remote desktop with XFCE (any compute host; reached via the Guacamole gateway)";

    # xrdp/sesman.ini values
    maxSessions = mkOption {
      type = types.int;
      default = 50;
    };
    maxLoginRetry = mkOption {
      type = types.int;
      default = 4;
    };
    killDisconnected = mkOption {
      type = types.bool;
      default = true;
    };

    # ── XRDP TLS cert from the lab PKI ──────────────────────────────────────
    # XRDP otherwise generates a fresh self-signed cert whenever one is missing; on an
    # impermanent host that's a NEW cert every rollback, so each RDP client hits a
    # cert-TOFU mismatch (the Guacamole→host break worked around with ignore-cert).
    # Opt in here and the host's vault-agent issues a `host` cert from the lab CA
    # (terraform/openbao pki_int) into /run tmpfs and re-issues it each boot; clients
    # that trust the CA root fleet-wide (profiles/base.nix security.pki) validate the
    # rotating leaf BY CHAIN — no TOFU break, nothing durable to persist.
    tlsCert = {
      enable = mkEnableOption "issue the XRDP TLS cert from the lab PKI (krg.vaultAgent + pki_int `host` role) instead of xrdp's per-boot self-signed cert";

      commonName = mkOption {
        type = types.str;
        default = "${config.networking.hostName}.krg.local";
        defaultText = literalExpression ''"''${config.networking.hostName}.krg.local"'';
        description = "CN / DNS SAN of the issued cert — the host's AD FQDN (under krg.local, which the `host` role permits).";
      };

      ipSans = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["137.110.161.67"];
        description = ''
          IP SANs to include. Set the box's RDP-facing IP — the Guacamole gateway
          usually dials the host by IP, so that's the name the RDP client verifies.
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.xrdp = {
        enable = true;
        defaultWindowManager = "${pkgs.xfce4-session}/bin/xfce4-session";
        # Firewall is managed by krg.firewall (allowRDP = true opens 3389)
        openFirewall = false;
      };

      services.xserver = {
        enable = true;
        desktopManager.xfce.enable = true;
      };

      environment.systemPackages = with pkgs; [
        xfce4-session
        xfwm4
        xfce4-panel
        xfdesktop # <--- This handles the wallpaper
        xfce4-settings # <--- This provides the menu to change wallpapers
        xfconf # <--- The configuration storage system
        firefox
        xhost
      ];

      # RDP access group: created AND assigned only when XRDP is enabled, so it's not
      # a blanket default group (see profiles/compute.nix). The local break-glass admin
      # (a krg.users account) picks it up via defaultGroups; AD users' RDP membership
      # comes from AD. This also means the group always exists when something references it.
      users.groups.rdp_users = {};
      krg.users.defaultGroups = ["rdp_users"];
    })

    (mkIf (cfg.enable && tls.enable) {
      # Secret-zero: the AppRole secret_id sits at the vault-agent default
      # /var/lib/krg/openbao-agent/secret-id — /var/lib/krg is persisted (impermanence
      # directories), so it survives the rollback. Mint + place it out-of-band; see
      # docs/pki-ad-integration.md. Each XRDP host needs its OWN AppRole in
      # terraform/openbao granting pki_int/issue/host (e.g. `waiter`, `kastner-ml`).
      krg.vaultAgent = {
        enable = true;
        # ONE pki_int/issue call mints one matched keypair → render cert+chain+key to a
        # single bundle. Two separate templates would be two issues → a mismatched key.
        renders = [
          {
            destination = "/run/xrdp-tls/bundle.pem";
            perms = "0640";
            contents = ''
              {{- with secret "pki_int/issue/host" ${certSecretArgs} }}
              {{ .Data.certificate }}
              {{- range .Data.ca_chain }}
              {{ . }}
              {{- end }}
              {{ .Data.private_key }}
              {{- end }}
            '';
          }
        ];
      };

      # xrdp wants the cert and key as SEPARATE files; split the single-issue bundle
      # (one keypair) rather than issuing twice. cert.pem keeps leaf+chain so xrdp
      # presents the full chain and clients anchor on the trusted CA root.
      systemd.services.xrdp-tls-split = {
        description = "Split the vault-agent PKI bundle into XRDP cert/key files";
        after = ["openbao-agent.service"];
        requires = ["openbao-agent.service"];
        before = ["xrdp.service"];
        wantedBy = ["xrdp.service"];
        unitConfig.ConditionPathExists = "/run/xrdp-tls/bundle.pem";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "xrdp-tls-split" ''
            set -euo pipefail
            cd /run/xrdp-tls
            ${pkgs.gawk}/bin/awk '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/' bundle.pem > cert.pem
            ${pkgs.gawk}/bin/awk '/-BEGIN [A-Z ]*PRIVATE KEY-/,/-END [A-Z ]*PRIVATE KEY-/' bundle.pem > key.pem
            chmod 0640 cert.pem key.pem
          '';
        };
      };

      # Point xrdp at the rendered cert/key and make it wait for the split.
      services.xrdp.sslCert = "/run/xrdp-tls/cert.pem";
      services.xrdp.sslKey = "/run/xrdp-tls/key.pem";
      systemd.services.xrdp = {
        after = ["xrdp-tls-split.service"];
        requires = ["xrdp-tls-split.service"];
      };
    })
  ];
}
