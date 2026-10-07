# Reclaim superseded docker images after each compose-stack converge. Mirrors
# fishsense-services deploy/incus/prune.nix (whose slot filled its disk on 2026-07-16
# with stale image versions: postgres `No space left on device`).
#
# Ordered AFTER `reference-manager.service` (the compose stack) and pulled in whenever
# it starts, so the reclaim runs right after `up -d` has the new containers running
# (their images in use, therefore kept).
#
# FILTERED, unlike fishsense's bare `-af`: only images older than 72h. A bare `-a -f`
# also removes the image of any container that happens to be STOPPED at that moment,
# and the next converge then fails "No such image" (krg-infra hit this on krg-prod).
# 72h still reclaims every previous release on a 60G disk.
#
# Deliberately `wantedBy` (not `requiredBy`) and no `bindsTo`: a prune failure must
# never fail or block the stack — worst case the disk isn't reclaimed this time.
{config, ...}: {
  systemd.services.reference-manager-image-prune = {
    description = "Reclaim superseded docker images after the compose-stack converge";
    after = ["reference-manager.service"];
    wantedBy = ["reference-manager.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.virtualisation.docker.package}/bin/docker image prune -af --filter until=72h";
    };
  };
}
