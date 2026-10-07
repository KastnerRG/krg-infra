# Populate the composeStack working directory. Mirrors fishsense-services
# deploy/incus/workdir.nix.
#
# The krg composeStack runner (krg-infra services/compose-stack.nix) invokes our
# compose with `--project-directory /var/lib/krg/reference-manager`, so docker resolves
# the compose file's RELATIVE bind paths (`./traefik-dynamic.yml`) against THAT dir,
# not the Nix-store compose dir. Symlink the repo-committed READ-ONLY config into it,
# pointing at the flake's store copy (the store path changes on every config edit, so
# `L+` refreshes the link each converge — repo-owns-deploy preserved).
#
# Every `./x` the compose names MUST be linked here. A forgotten one is SILENT: docker
# creates a missing bind source as an empty directory, and the container comes up with
# nothing in it (fishsense-lite's nrp_cert_sync lesson).
{
  systemd.tmpfiles.rules = [
    "L+ /var/lib/krg/reference-manager/traefik-dynamic.yml - - - - ${./traefik-dynamic.yml}"
  ];
}
