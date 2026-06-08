# Shared AD-group → local-group bridge.
#
# SSSD algorithmic ID mapping derives an AD group's GID from its SID, so an AD group
# can never BE a fixed/local group (cuda's device GID, docker's daemon group, …).
# This module instead re-derives a LOCAL group's membership from one or more named
# AD groups: for each entry `krg.adGroupSync.<name>`, a oneshot `<name>-group-sync`
# (+ a 10-min timer) runs getent → gpasswd -M, UNIONing the resolved AD members with
# the group's locally-declared members.
#
# WHY A TIMER (not a one-shot at switch): the synced members are NOT durable — every
# nixos-rebuild regenerates /etc/group with only the DECLARED members, and on
# impermanence hosts the root is rolled back each boot — so the timer re-applies them.
#
# Consumers wire their own semantic options into this rather than hand-rolling the
# unit: modules/hardware/nvidia.nix (krg.nvidia.cudaAccessGroups → GPU device group)
# and modules/docker.nix (krg.docker.accessGroups → the Docker daemon group).
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.krg.adGroupSync;
  # An entry with no AD groups generates no unit (nothing to sync).
  active = filterAttrs (_: b: b.adGroups != []) cfg;

  # Local accounts the flake declares directly into <localGroup>: users that list it
  # in extraGroups, plus the group's own declared members. `gpasswd -M` REPLACES the
  # whole member list, so these must be re-added on every sync or the bridge would
  # silently drop them (e.g. the break-glass admin via krg.users.defaultGroups). The
  # `or []` tolerates a localGroup that isn't otherwise declared. Lazy: only forced
  # for groups that actually have an active bridge.
  declaredMembers = localGroup:
    unique (
      (attrNames (filterAttrs (_: u: elem localGroup u.extraGroups) config.users.users))
      ++ (config.users.groups.${localGroup}.members or [])
    );

  syncScript = b: ''
    set -uo pipefail
    adgroups=( ${escapeShellArgs b.adGroups} )
    declared=${escapeShellArg (concatStringsSep "," (declaredMembers b.localGroup))}
    target=${escapeShellArg b.localGroup}
    members=""
    resolved=0
    for g in "''${adgroups[@]}"; do
      if line=$(getent group "$g" 2>/dev/null); then
        resolved=1
        m=$(printf '%s' "$line" | cut -d: -f4)
        [ -n "$m" ] && members="''${members:+$members,}$m"
      else
        echo "$target-group-sync: AD group '$g' did not resolve (SSSD/AD down?); skipping" >&2
      fi
    done
    # Only a TOTAL failure to resolve is treated as an outage (leave membership
    # alone), so a transient SSSD/AD outage never wipes access. A group that resolves
    # but is empty IS applied, so removing a member from AD revokes their access.
    if [ "$resolved" -eq 0 ]; then
      echo "$target-group-sync: no AD group resolved (SSSD/AD down?); leaving local '$target' group unchanged (fail-safe)" >&2
      exit 0
    fi
    # Union the AD members with the locally-declared members (e.g. break-glass admin);
    # gpasswd -M replaces the whole list, so omitting them would drop them.
    all=$(printf '%s\n%s\n' "$(printf '%s' "$members"  | tr ',' '\n')" \
                            "$(printf '%s' "$declared" | tr ',' '\n')" \
          | sed '/^$/d' | sort -u | paste -sd, -)
    echo "$target-group-sync: setting '$target' group members to: ''${all:-(none)}"
    gpasswd -M "$all" "$target"
  '';
in {
  options.krg.adGroupSync = mkOption {
    default = {};
    description = ''
      AD-group → local-group bridges. For each attribute `<name>`, members of the
      listed `adGroups` are synced into the local group `localGroup` (default: the
      attribute name) by a boot+timer oneshot `<name>-group-sync`. Used to grant
      access that SSSD's SID-derived GIDs can't land on a fixed local group (the GPU
      device group, the Docker daemon group). Fail-safe: leaves the local group
      unchanged when no AD group resolves (SSSD/AD down). An entry whose `adGroups`
      is empty generates no unit.
    '';
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        localGroup = mkOption {
          type = types.str;
          default = name;
          description = "Local group whose membership is synced (defaults to the attribute name).";
        };
        adGroups = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["Docker Users"];
          description = "AD groups whose members are bridged into localGroup. Empty = no unit generated.";
        };
      };
    }));
  };

  config = {
    systemd.services = mapAttrs' (name: b:
      nameValuePair "${name}-group-sync" {
        description = "Sync AD group members into the local ${b.localGroup} group";
        after = ["sssd.service" "network-online.target"];
        wants = ["sssd.service" "network-online.target"];
        # getent MUST be pkgs.getent (the NixOS NSS-correct build), NOT pkgs.glibc.bin:
        # the raw glibc getent can't load the `sss` NSS module in a unit, so AD group
        # lookups silently return nothing.
        path = [pkgs.shadow pkgs.coreutils pkgs.gnused pkgs.getent];
        serviceConfig.Type = "oneshot";
        script = syncScript b;
      })
    active;

    systemd.timers = mapAttrs' (name: _:
      nameValuePair "${name}-group-sync" {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "10min";
          Persistent = true;
        };
      })
    active;
  };
}
