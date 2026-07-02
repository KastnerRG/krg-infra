{
  pkgs,
  config,
  ...
}: {
  imports = [
    # server tier (= old base + node-exporter): an always-on monitored infra VM.
    # krg.users + the break-glass admin now come via base.nix (imported by server).
    ../../profiles/server.nix
    ./hardware-configuration.nix
  ];

  krg.adminAccount = "krg-admin";

  # Proxmox VM — QEMU guest agent; in-guest firewall stays ON.
  krg.base = {
    enable = true;
    autoUpgrade = true;
    serviceHost = true; # restrict SSH to trusted UCSD nets in-guest
    isVM = true;
  };

  # SSH (22) inherits from base.nix's default allowedTCPPorts = [22];
  # serviceHost = true (also from base.nix default) restricts it to ucsd + ops
  # via sshSources. node-exporter's 9100 is auto-opened to the monitoring host by
  # nix/modules/services/node-exporter.nix (issue #234) — no krg.firewall block
  # needed here.

  # OEC (Qualys + Trellix). krg-deploy is EXCLUDED from the push deploy's
  # stage+verify (deploy/deploy-nixos.sh — a self-rebuild would restart this
  # runner mid-job), so it isn't staged the way the rest of the fleet is. Instead
  # point the module at the credentialed archive the control node ALREADY holds
  # (it's the OEC_INSTALLER deploy source): its nightly autoUpgrade rebuild then
  # fires oec-install and enrolls with no extra staging. deploy-nixos.sh verifies
  # this host's daemons LOCALLY at the end of each run.
  krg.oecQualysTrellix.installerArchive = "/var/lib/krg-admin/.secrets/oec-qualystrellixinstallers-linux.tgz";

  networking = {
    hostName = "krg-deploy";
    domain = "ucsd.edu";
    useDHCP = false;
    interfaces.ens18.ipv4.addresses = [
      {
        address = "137.110.161.122";
        prefixLength = 24;
      }
    ];
    defaultGateway = "137.110.161.1";
    nameservers = ["132.239.0.252" "8.8.8.8" "1.1.1.1"];
  };

  # Ansible control node + OpenTofu for infrastructure provisioning.
  environment.systemPackages = with pkgs; [
    ansible
    opentofu
    openbao # bao CLI — talks to krg-vault for secrets management
    incus # incus CLI — the control plane for the krg-nat Incus platform: one-time
    #        trust bootstrap (`incus remote add krg-nat <token>`) that populates the
    #        config dir the terraform/incus provider reads, plus ongoing management.
    python3 # ansible runtime dependency
    sshpass # needed by some ansible connection scenarios
    jq
  ];

  # Point bao at krg-vault so every shell session works without manual export.
  environment.variables.VAULT_ADDR = "https://krg-vault.ucsd.edu:8200";

  # AD domain member — joined 2026-06-18 (adcli; testjoin OK). Explicit marker;
  # base.nix defaults krg.adClient.enable on. adClient prepends the DC as the primary
  # resolver (krg-deploy had campus-only DNS before).
  krg.adClient.enable = true;

  # ── Fleet SSH host keys (deploy trust anchor) ───────────────────────────────
  # Renders /etc/ssh/ssh_known_hosts so the push deploy (deploy/deploy-nixos.sh,
  # StrictHostKeyChecking=yes) and the Ansible leg (host_key_checking=True) trust
  # the fleet without trust-on-first-use. System-wide, so it applies regardless of
  # which HOME the github-runner service uses.
  #
  # INTERIM: pinned per-host keys are rebuild-fragile — a host reinstalled from
  # scratch regenerates its key and the pin must be updated here + krg-deploy
  # redeployed. The rebuild-proof replacement (OpenBao SSH host CA → trust one CA,
  # not N keys) is tracked in #130. Re-pull a key from the host's own
  # /etc/ssh/ssh_host_ed25519_key.pub (trusted channel) if it ever changes.
  programs.ssh.knownHosts = {
    krg-vault = {
      hostNames = ["krg-vault.ucsd.edu" "137.110.161.123"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtSXiHTb0pe3ST5L2bMwbLEQxc/SXx3590fPHWR5feP";
    };
    krg-ldap = {
      hostNames = ["krg-ldap.ucsd.edu" "137.110.161.109"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBjXnLvMjFvKJjRE2BhhD7Arx2PzXXbQbjFbSCZKizQ";
    };
    waiter = {
      hostNames = ["waiter.ucsd.edu" "137.110.161.67"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINf+Y0cKbiA1tyroR3QM2XK86ZPDC3JSsevNPYiTDYw/";
    };
    # krg-prod was REINSTALLED (fresh key, root@nixos) — the old fabricant-prod key
    # did NOT match. Confirmed 2026-06-04 via an authenticated SSH session to the
    # live host: `cat /etc/ssh/ssh_host_ed25519_key.pub`.
    krg-prod = {
      hostNames = ["krg-prod.ucsd.edu" "137.110.161.106"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILeQ8gYCBKrTWwDGtvcGrBA9/efa7T0N6rndXYI5yVAV";
    };
    # E4E GPU compute box, provisioned via nixos-anywhere (fresh key). Deployed as
    # e4e-admin (deploy/deploy-nixos.sh USER_OVERRIDE). SHA256:VD/h/Bv4QFcj7V+WwipAZdtFtjUabQFfctX8w2LZXRQ
    kastner-ml = {
      hostNames = ["kastner-ml.ucsd.edu" "132.239.17.123"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDNW45FIs6o2rMuemY+a7SHjSCby9txBmzjTLAkp/LDh";
    };
    # Proxmox hypervisor — for the Ansible leg (deploy-ansible.sh → root@fabricant).
    fabricant = {
      hostNames = ["fabricant.ucsd.edu"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN846n66tuIGzD33kP6HKCVf7s7nAS+HkNBtTObQ2OFW";
    };
    # Synology NAS — for the Ansible synology leg (ansible/synology connects to
    # e4e-admin@e4e-nas by IP via inventory.yml ansible_host, so pin both names).
    e4e-nas = {
      hostNames = ["e4e-nas.ucsd.edu" "132.239.17.124"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcS4fE6LEZa4QavcZr4Xi8Bv84ZReg75Wwky5a7rgoH";
    };
    # E4E student-project tenant platform (Proxmox VM). Deployed as e4e-admin
    # (deploy/lib.sh USER_OVERRIDE). Key captured from the first install
    # (2026-06-23); if the host is REINSTALLED the key changes — refresh from
    # `cat /etc/ssh/ssh_host_ed25519_key.pub` on the live host (cf. krg-prod above).
    e4e-prod = {
      hostNames = ["e4e-prod.ucsd.edu" "137.110.161.107"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK/Vl31g2FSV51OdRO7iuIBjSF2JbtvIDRQTZozkMpQb";
    };
    # Incus platform host (Proxmox VM). Deployed as krg-admin (default; no
    # USER_OVERRIDE). Key captured from the first install (2026-07-01); if the host is
    # REINSTALLED the key changes — refresh from `cat /etc/ssh/ssh_host_ed25519_key.pub`
    # on the live host (cf. krg-prod above).
    krg-nat = {
      hostNames = ["krg-nat.ucsd.edu" "137.110.161.105"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM00Znu//PplzyO4SaszlHV9pR6DGGu1gcJKHhIdlnc3";
    };
  };

  # ── GitHub Actions self-hosted runner ──────────────────────────────────────
  # Push-to-main continuous deploy (.github/workflows/deploy.yml). Runs as the
  # break-glass admin so it reuses krg-admin's existing fleet identity — the same
  # SSH keys + sudoNoPassword the nightly ansible-apply timer below already uses
  # to reach every host. The workflow is GATED on green CI before it applies.
  #
  # Secrets — NOT in git (operator-provisioned, mirrors the .secrets/ pattern):
  #   /var/lib/krg-admin/.secrets/github-runner-token
  #       a runner registration token, or a fine-grained PAT with the repo's
  #       "Administration" read/write scope, used to register the runner.
  #       BRING-UP: a short-lived registration token for now; move to a
  #       lab-owned bot-account PAT stored in OpenBao — tracked in #121.
  #   /var/lib/krg-admin/.ssh/id_ed25519
  #       krg-admin's private key to the fleet (already required by ansible-apply).
  #   /var/lib/krg-admin/.secrets/openbao-role-id
  #   /var/lib/krg-admin/.secrets/openbao-secret-id
  #       krg-deploy's OpenBao AppRole creds (role_id is non-secret, secret_id is).
  #       deploy-ansible.sh logs in with these to read secret/e4e-nas/* from
  #       krg-vault and materialize them as ansible extra_vars for the synology
  #       playbook. Provision: role_id from terraform/openbao output; secret_id
  #       via `bao write -f auth/approle/role/krg-deploy/secret-id` (krg-deploy's
  #       own policy can mint these). The read capability is in terraform/openbao.
  # The deploy sources per-layer secrets at run time (see deploy/*.sh):
  #   tofu   — krg-deploy AppRole login → bao kv get per target (+ the
  #            TOFU_STATE_PASSPHRASE Actions secret for state encryption).
  #   ansible (synology) — krg-deploy AppRole login → bao kv get → extra_vars.
  services.github-runners.krg-deploy = {
    enable = true;
    name = "krg-deploy";
    url = "https://github.com/KastnerRG/krg-infra";
    tokenFile = "/var/lib/krg-admin/.secrets/github-runner-token";
    user = "krg-admin"; # reuse the control-node identity (SSH + sudo + tofu state)
    replace = true; # re-register if a stale runner of this name exists
    extraLabels = ["krg-deploy"]; # deploy.yml targets [self-hosted, krg-deploy]
    # The deploy toolchain on the runner's PATH (system-wide pkgs aren't on the
    # service PATH). nixos-rebuild evaluates the flake (needs nix + git); the rest
    # drive the Ansible / OpenTofu / OpenBao layers.
    extraPackages = with pkgs; [
      nix
      nixos-rebuild
      git
      openssh
      ansible
      opentofu
      openbao
      python3
      jq
      sshpass
      gnused
      gawk
      coreutils
    ];
    # OpenTofu state must persist across runner jobs (the work dir is ephemeral)
    # and deploy/deploy-tofu.sh writes it under /var/lib/krg-admin/tofu-state. The
    # runner unit is ProtectSystem=strict (the nixpkgs github-runner default — the
    # whole FS is read-only bar a few allow-listed paths), so without this the
    # script's `mkdir tofu-state` fails with EROFS. Grant write access to JUST that
    # one dir (pre-created by the tmpfiles rule below — ReadWritePaths entries must
    # exist at unit start). deploy-tofu.sh reads its per-target creds from OpenBao
    # (AppRole), so there's no secrets dir to grant — and the AppRole role/secret
    # id files in /var/lib/krg-admin/.secrets/ are READS, which ProtectSystem=strict
    # already permits (same as the Ansible leg).
    serviceOverrides.ReadWritePaths = ["/var/lib/krg-admin/tofu-state"];
  };

  # Pre-create the OpenTofu state dir (owner-only — it holds encrypted state) so
  # the runner's ReadWritePaths entry above exists at unit start. krg-admin's
  # primary group is `users` (isNormalUser default).
  systemd.tmpfiles.rules = [
    "d /var/lib/krg-admin/tofu-state 0700 krg-admin users - -"
  ];

  # Periodic Ansible apply — mirrors NixOS autoUpgrade on the Ansible layer.
  # Pulls main and runs deploy/deploy-ansible.sh nightly (Proxmox site.yml + the
  # e4e-nas converge); drift gets corrected automatically. openbao + jq +
  # coreutils are for deploy-ansible.sh's OpenBao secret materialization.
  systemd.services.ansible-apply = {
    description = "Apply Ansible playbooks to managed infrastructure";
    path = [pkgs.openssh pkgs.git pkgs.ansible pkgs.python3 pkgs.openbao pkgs.jq pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      User = "krg-admin";
      WorkingDirectory = "/var/lib/krg-admin";
      ExecStart = pkgs.writeShellScript "ansible-apply" ''
        # Bootstrap: clone on first run if the repo isn't present yet.
        # Uses HTTPS so no deploy key is needed for the initial pull.
        if ! ${pkgs.git}/bin/git -C /var/lib/krg-admin/krg-infra \
              rev-parse --git-dir >/dev/null 2>&1; then
          ${pkgs.git}/bin/git clone \
            https://github.com/KastnerRG/krg-infra.git \
            /var/lib/krg-admin/krg-infra
        fi
        ${pkgs.git}/bin/git -C /var/lib/krg-admin/krg-infra pull --ff-only
        # Same entrypoint as the push-CD (deploy.yml): site.yml (Proxmox) + the
        # e4e-nas converge. DEPLOY_SYNOLOGY=true includes the NAS — inert until
        # the OpenBao AppRole creds are provisioned (graceful skip otherwise),
        # so provisioning them is the go-live switch. deploy-ansible.sh resolves
        # REPO_ROOT from its own path, so no cd is needed.
        #
        # FULL converge (no SYNOLOGY_TAGS) — bring-up scoping lifted after a clean
        # read-only `--check --diff` of the whole playbook (#165): 0 failures, 0
        # deletions. SNMP stays off in spec (#151), mail deferred in group_vars
        # (#163). Keep in lockstep with deploy.yml.
        DEPLOY_SYNOLOGY=true \
          ${pkgs.bash}/bin/bash /var/lib/krg-admin/krg-infra/deploy/deploy-ansible.sh
      '';
    };
  };

  systemd.timers.ansible-apply = {
    description = "Nightly Ansible apply";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "04:30"; # 30 min after NixOS autoUpgrade so NixOS lands first
      Persistent = true; # catch up if the machine was off at fire time
    };
  };

  # ── Control-node self-update (multistage push deploy, ADR 0011) ─────────────
  # The push deploy (deploy/deploy-self-update.sh) cannot switch krg-deploy INLINE:
  # the github-runner that runs it is a hardened sandbox (NoNewPrivileges +
  # ProtectSystem=strict), so it can neither escalate (sudo) nor run a system switch
  # in its own mount namespace. Instead the runner (as krg-admin) asks PID 1 to run
  # THIS root, host-context oneshot via `systemctl start --no-block` — authorized by
  # the polkit rule below, NO sudo, and with the runner's own hardening left intact.
  #
  # The service: delays briefly (so the triggering deploy job finishes and reports),
  # stops the runner for the whole switch (a clean offline→online the external watcher
  # deploy/await-self-update.sh keys on), switches to the flake's krg-deploy config
  # (SAME source as the nightly system.autoUpgrade — github main, pinned lock), brings
  # the runner back on the new code, and records status for deploy/deploy-self-verify.sh.
  # Switch-only — never reboots the control node.
  #
  # BOOTSTRAP: this unit + polkit rule must already be ON krg-deploy before the push
  # path can trigger it — land it via one nightly autoUpgrade or a manual
  # `nixos-rebuild switch` first (deploy-self-update.sh fails with a clear message
  # until then).
  systemd.services.krg-deploy-selfupdate = {
    description = "krg-deploy control-node self-update (detached switch)";
    # Do NOT let a `switch` that changes this very unit stop/restart the in-flight
    # self-update — that would kill the switch mid-run.
    restartIfChanged = false;
    stopIfChanged = false;
    path = [pkgs.nixos-rebuild pkgs.systemd pkgs.coreutils pkgs.git pkgs.openssh config.nix.package];
    serviceConfig = {
      Type = "oneshot";
      # Give the triggering deploy job time to finish + report success before we take
      # the runner offline. The rest of the deploy is gated on the external watcher,
      # not this delay, so a generous value is free.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 45";
    };
    script = ''
      set -uo pipefail
      STATUS=/var/lib/krg/selfupdate.status
      RUNNER=github-runner-krg-deploy.service
      install -d -m 0755 /var/lib/krg
      printf 'running\n' >"$STATUS"
      # Offline for the whole switch so the watcher observes a clean offline→online
      # (a no-op / runner-unit-unchanged switch would otherwise never restart it).
      systemctl stop "$RUNNER" || true
      if nixos-rebuild switch --flake ${config.krg.base.flakeUrl}#krg-deploy --refresh; then
        printf 'ok %s\n' "$(readlink -f /run/current-system)" >"$STATUS"
        rc=0
      else
        printf 'failed switch\n' >"$STATUS"
        rc=1
      fi
      # Bring the runner back on the new code (idempotent if the switch already did).
      systemctl start "$RUNNER" || true
      exit "$rc"
    '';
  };

  # Authorize the runner user (krg-admin) to start ONLY that one unit — no sudo, so
  # the runner keeps its NoNewPrivileges/ProtectSystem sandbox. Scoped to the single
  # unit + user; everything else still requires root.
  #
  # polkit MUST be enabled for the rule below to take effect: without a running
  # polkitd, systemd denies a non-root `systemctl start` of a system unit outright
  # ("Access denied") and the extraConfig rule is never consulted. security.polkit is
  # off by default on this server, so enable it explicitly here.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "krg-deploy-selfupdate.service" &&
          subject.user == "krg-admin") {
        return polkit.Result.YES;
      }
    });
  '';

  system.stateVersion = "25.11";
}
