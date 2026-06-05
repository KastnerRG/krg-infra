{ pkgs, ... }: {
  imports = [
    ../../profiles/base.nix
    ../../modules/users.nix
    ../../users/admin.nix
    ./hardware-configuration.nix
  ];

  krg.adminAccount = "krg-admin";

  # Proxmox VM — QEMU guest agent; in-guest firewall stays ON.
  krg.base = {
    enable      = true;
    autoUpgrade = true;
    serviceHost = true;   # restrict SSH to trusted UCSD nets in-guest
    isVM        = true;
  };

  krg.firewall = {
    # SSH (22) inherits from base.nix's default allowedTCPPorts = [22];
    # serviceHost = true (also from base.nix default) restricts it to
    # ucsd + ops via sshSources. node-exporter monitoring on 9100.
    monitoringPorts = [ 9100 ];
  };

  networking = {
    hostName = "krg-deploy";
    domain   = "ucsd.edu";
    useDHCP  = false;
    interfaces.ens18.ipv4.addresses = [{
      address      = "137.110.161.122";
      prefixLength = 24;
    }];
    defaultGateway = "137.110.161.1";
    nameservers    = [ "132.239.0.252" "8.8.8.8" "1.1.1.1" ];
  };

  # Ansible control node + OpenTofu for infrastructure provisioning.
  environment.systemPackages = with pkgs; [
    ansible
    opentofu
    openbao     # bao CLI — talks to krg-vault for secrets management
    python3     # ansible runtime dependency
    sshpass     # needed by some ansible connection scenarios
    jq
  ];

  # Point bao at krg-vault so every shell session works without manual export.
  environment.variables.VAULT_ADDR = "https://krg-vault.ucsd.edu:8200";

  # Not yet domain-joined — disable AD client until keytab is provisioned.
  krg.adClient.enable = false;

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
      hostNames = [ "krg-vault.ucsd.edu" "137.110.161.123" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtSXiHTb0pe3ST5L2bMwbLEQxc/SXx3590fPHWR5feP";
    };
    krg-ldap = {
      hostNames = [ "krg-ldap.ucsd.edu" "137.110.161.109" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMBjXnLvMjFvKJjRE2BhhD7Arx2PzXXbQbjFbSCZKizQ";
    };
    waiter = {
      hostNames = [ "waiter.ucsd.edu" "137.110.161.67" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINf+Y0cKbiA1tyroR3QM2XK86ZPDC3JSsevNPYiTDYw/";
    };
    # krg-prod was REINSTALLED (fresh key, root@nixos) — the old fabricant-prod key
    # did NOT match. Confirmed 2026-06-04 via an authenticated SSH session to the
    # live host: `cat /etc/ssh/ssh_host_ed25519_key.pub`.
    krg-prod = {
      hostNames = [ "krg-prod.ucsd.edu" "137.110.161.106" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILeQ8gYCBKrTWwDGtvcGrBA9/efa7T0N6rndXYI5yVAV";
    };
    # Proxmox hypervisor — for the Ansible leg (deploy-ansible.sh → root@fabricant).
    fabricant = {
      hostNames = [ "fabricant.ucsd.edu" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN846n66tuIGzD33kP6HKCVf7s7nAS+HkNBtTObQ2OFW";
    };
    # Synology NAS — for the Ansible synology leg (ansible/synology connects to
    # e4e-admin@e4e-nas by IP via inventory.yml ansible_host, so pin both names).
    e4e-nas = {
      hostNames = [ "e4e-nas.ucsd.edu" "132.239.17.124" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcS4fE6LEZa4QavcZr4Xi8Bv84ZReg75Wwky5a7rgoH";
    };
    # e4e-prod omitted — host not provisioned yet (also absent from deploy ORDER).
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
  #   tofu   — terraform/<target>/.deploy-env + the TOFU_STATE_PASSPHRASE secret.
  #   ansible (synology) — krg-deploy AppRole login → bao kv get → extra_vars.
  services.github-runners.krg-deploy = {
    enable      = true;
    name        = "krg-deploy";
    url         = "https://github.com/KastnerRG/krg-infra";
    tokenFile   = "/var/lib/krg-admin/.secrets/github-runner-token";
    user        = "krg-admin";   # reuse the control-node identity (SSH + sudo + tofu state)
    replace     = true;          # re-register if a stale runner of this name exists
    extraLabels = [ "krg-deploy" ];   # deploy.yml targets [self-hosted, krg-deploy]
    # The deploy toolchain on the runner's PATH (system-wide pkgs aren't on the
    # service PATH). nixos-rebuild evaluates the flake (needs nix + git); the rest
    # drive the Ansible / OpenTofu / OpenBao layers.
    extraPackages = with pkgs; [
      nix nixos-rebuild git openssh
      ansible opentofu openbao python3
      jq sshpass gnused gawk coreutils
    ];
  };

  # Periodic Ansible apply — mirrors NixOS autoUpgrade on the Ansible layer.
  # Pulls main and runs deploy/deploy-ansible.sh nightly (Proxmox site.yml + the
  # e4e-nas converge); drift gets corrected automatically. openbao + jq +
  # coreutils are for deploy-ansible.sh's OpenBao secret materialization.
  systemd.services.ansible-apply = {
    description = "Apply Ansible playbooks to managed infrastructure";
    path = [ pkgs.openssh pkgs.git pkgs.ansible pkgs.python3 pkgs.openbao pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type             = "oneshot";
      User             = "krg-admin";
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
        DEPLOY_SYNOLOGY=true \
          ${pkgs.bash}/bin/bash /var/lib/krg-admin/krg-infra/deploy/deploy-ansible.sh
      '';
    };
  };

  systemd.timers.ansible-apply = {
    description = "Nightly Ansible apply";
    wantedBy    = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "04:30";   # 30 min after NixOS autoUpgrade so NixOS lands first
      Persistent = true;      # catch up if the machine was off at fire time
    };
  };

  system.stateVersion = "25.11";
}
