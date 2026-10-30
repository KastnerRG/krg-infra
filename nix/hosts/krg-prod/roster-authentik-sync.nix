{pkgs, ...}: let
  queueRoot = "/run/krg/authentik-ldap-sync";
  worker = pkgs.writeShellApplication {
    name = "roster-authentik-sync";
    runtimeInputs = [pkgs.coreutils pkgs.docker];
    text = builtins.readFile ../../modules/services/authentik-ldap-sync/worker.sh;
  };
in {
  # UID 1001 is the roster image's appuser. Only this isolated queue is writable;
  # the backend never receives the Docker socket, sudo, or an Authentik admin token.
  systemd.tmpfiles.rules = [
    "d ${queueRoot} 0755 root root -"
    "d ${queueRoot}/requests 0700 1001 root -"
  ];

  systemd.paths.roster-authentik-sync = {
    description = "Watch roster LDAP changes for Authentik reconciliation";
    wantedBy = ["multi-user.target"];
    after = ["systemd-tmpfiles-setup.service"];
    pathConfig = {
      PathExists = ["${queueRoot}/requests/pending" "${queueRoot}/processing"];
      Unit = "roster-authentik-sync.service";
    };
  };

  systemd.services.roster-authentik-sync = {
    description = "Reconcile the Authentik LDAP source after roster writes";
    after = ["docker.service" "krg-prod.service"];
    requires = ["docker.service"];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      # Coalesce edits made together (e.g. profile + groups), and limit sync rate.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${worker}/bin/roster-authentik-sync ${queueRoot}/requests ${queueRoot}/processing docker --host unix:///var/run/docker.sock exec authentik_worker ak ldap_sync krg-samba-ad";
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "15min";
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [queueRoot];
      RestrictAddressFamilies = ["AF_UNIX"];
    };
  };
}
