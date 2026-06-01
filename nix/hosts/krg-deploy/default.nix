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

  # Periodic Ansible apply — mirrors NixOS autoUpgrade on the Ansible layer.
  # Pulls main and runs site.yml nightly; drift gets corrected automatically.
  systemd.services.ansible-apply = {
    description = "Apply Ansible playbooks to managed infrastructure";
    path = [ pkgs.openssh pkgs.git pkgs.ansible pkgs.python3 ];
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
        # cd into ansible/ so ansible.cfg is found and roles_path = roles resolves correctly.
        cd /var/lib/krg-admin/krg-infra/ansible
        ${pkgs.ansible}/bin/ansible-playbook playbooks/site.yml
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
