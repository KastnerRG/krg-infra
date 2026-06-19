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

    # --- Technology-control-plan gate on the CLIENTLESS (Guacamole) RDP path ---
    #
    # Some populations (the ARM PDK engineers + everyone who can sudo) must reach
    # waiter's desktop ONLY over an auditable SSH tunnel (key-based, logged), never
    # via the one-click Guacamole browser RDP. Guacamole itself can't enforce this:
    # its admins are superusers and superusers can launch any connection (there is no
    # per-connection deny). So enforcement lives HERE, at waiter's xrdp auth, where
    # the two paths ARE distinguishable by RDP source IP:
    #   - Guacamole  -> guacd on krg-prod -> waiter:3389, source = krg-prod (gateway).
    #   - SSH tunnel -> ssh -L 3389:localhost:3389 -> waiter:3389, source = 127.0.0.1.
    # A pam_access rule on the xrdp-sesman account stack denies the listed groups when
    # the session originates from `gatewayDeny.sources`; loopback (the tunnel) is never
    # matched, so tunnel+RDP keeps working. Researchers NOT in those groups keep
    # clientless RDP. See docs/arm-pdk-tcp.md (incl. the PAM_RHOST validation step and
    # the root-on-waiter caveat).
    gatewayDeny = {
      enable = mkEnableOption "denying the ARM PDK / sudo set the clientless (Guacamole) RDP path, forcing them onto SSH-tunnel + RDP (technology control plan)";

      adGroups = mkOption {
        type = types.listOf types.str;
        default = ["ARM PDK Access"];
        description = ''
          AD groups blocked from the clientless gateway path. Everyone who can sudo is
          ALWAYS folded in on top of this (krg.adClient.sudoGroups is appended, plus
          local wheel is matched directly), so a user who gains sudo by any group path
          is captured even if not listed here. The names are bridged to a fixed-GID,
          space-free local group via krg.adGroupSync (pam_access can't reliably match
          AD group names containing spaces, e.g. "Domain Admins").
        '';
      };

      localGroup = mkOption {
        type = types.str;
        default = "armpdk-rdp-deny";
        description = "Fixed-GID local group that krg.adGroupSync populates from adGroups + sudoGroups; the pam_access deny keys on it.";
      };

      sources = mkOption {
        type = types.listOf types.str;
        default = config.krg.firewall.rdpSources;
        defaultText = literalExpression "config.krg.firewall.rdpSources";
        description = ''
          RDP source addresses that mean "arrived via the Guacamole gateway" — denied
          groups are refused from these origins. Defaults to the firewall's rdpSources
          (= krg-prod) so the gate and the firewall can't drift. Loopback (127.0.0.1,
          the SSH tunnel) is deliberately NOT listed, so tunnel+RDP is never blocked.
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

    (mkIf (cfg.enable && cfg.gatewayDeny.enable) (let
      gd = cfg.gatewayDeny;
      # The denied AD-group set: the explicit groups PLUS every AD group that grants
      # sudo (sssd-ad-client.nix grants sudo from krg.adClient.sudoGroups). Referencing
      # the live sudoGroups means adding a new sudo group later auto-extends the RDP
      # deny — the grant and the block can't drift apart.
      deniedADGroups = unique (gd.adGroups ++ config.krg.adClient.sudoGroups);
      # pam_access access.conf: deny the synced local group AND local wheel (the other
      # sudo path) from the gateway origins; permit everything else (incl. loopback =
      # the SSH tunnel, which never matches the origin list). `(group)` syntax + the
      # space-free localGroup sidesteps pam_access's inability to match AD names with
      # spaces. nodefgroup = bare tokens are never treated as netgroups.
      accessConf = pkgs.writeText "xrdp-gateway-access.conf" ''
        # Managed by krg.xrdp.gatewayDeny — nixos-rebuild reasserts this; do not edit.
        - : (${gd.localGroup}) (wheel) : ${concatStringsSep " " gd.sources}
        + : ALL : ALL
      '';
    in {
      assertions = [
        {
          assertion = gd.sources != [];
          message = ''
            krg.xrdp.gatewayDeny.enable is set but `sources` is empty (krg.firewall.rdpSources
            is also empty -> RDP 3389 is globally open). With no gateway origin to match, the
            deny rule can't distinguish Guacamole from the SSH tunnel. Set krg.firewall.rdpSources
            (the krg-prod IP) or krg.xrdp.gatewayDeny.sources explicitly. (host: ${config.networking.hostName})
          '';
        }
      ];

      # The local group the deny keys on, plus its AD->local bridge (10-min timer).
      users.groups.${gd.localGroup} = {};
      krg.adGroupSync.${gd.localGroup}.adGroups = deniedADGroups;

      # pam_access in the xrdp-sesman ACCOUNT phase. `required` -> a match (deny)
      # fails the account check and refuses the RDP login.
      #
      # ORDER IS LOAD-BEARING: it MUST run before pam_sss (order 10400), which is
      # `sufficient`. For an AD user pam_sss's account check succeeds, and a
      # `sufficient` success short-circuits the rest of the account stack — so a deny
      # placed AFTER pam_sss would never run for exactly the AD users (ARM PDK /
      # Domain Admins) we block. Run first (10300): a `required` failure here is
      # recorded and a later `sufficient` success can't override a prior required
      # failure, so the deny holds; a permit just falls through to pam_sss/pam_unix.
      security.pam.services.xrdp-sesman.rules.account.krgGatewayDeny = {
        control = "required";
        modulePath = "${pkgs.pam}/lib/security/pam_access.so";
        args = ["nodefgroup" "accessfile=${accessConf}"];
        order = 10300;
      };
    }))
  ];
}
