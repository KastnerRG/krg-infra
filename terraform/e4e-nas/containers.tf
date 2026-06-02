# Container Manager (Docker) workloads on e4e-nas.
#
# `synology_container_project` = a Docker Compose project managed via the DSM
# Container Manager API. Schema:
#   https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/container_project
#
# Compose source files live under terraform/e4e-nas/compose/. Anything with
# secrets is a .tftpl template rendered by templatefile() so the secrets come
# from sensitive variables (TF_VAR_garage_*) and never land in a .yml on disk.

# --- Garage S3 object store (ADR 0002 + 0003) --------------------------------
# Single-node cluster on the NAS, data on /volume2/s3-data, image pinned.
# After first `tofu apply`, the cluster needs ONE manual bootstrap step
# (operator-level — `garage layout assign` + `apply`; see PR description).
# Sub-PR 5 (#101) codifies via the garage_config Ansible role; until then
# it's an explicit operator one-shot.
resource "synology_container_project" "garage" {
  name = "garage"

  # Compose project working dir on the NAS. /volume1/docker/garage holds any
  # files Container Manager extracts (it does NOT need garage.toml here — the
  # toml is inlined via Compose `configs:` `content:` in the template).
  share_path = "/docker/garage"

  # Inline-rendered compose YAML. Secrets are pulled from sensitive variables;
  # the rendered content WILL appear in terraform state, so state encryption
  # matters (see ../README.md "State encryption").
  content = templatefile("${path.module}/compose/garage.yml.tftpl", {
    garage_image_tag = var.garage_image_tag
    rpc_secret       = var.garage_rpc_secret
    admin_token      = var.garage_admin_token
    metrics_token    = var.garage_metrics_token
  })

  # Same upstream Run-field-dropped bug as core_package (see ADR 0007 + the
  # synology_dsm_system `package-state` workaround). For container projects,
  # operator may need to manually start the project via Container Manager UI
  # after first apply if it doesn't auto-start. TODO: probe + work around
  # via a parallel Ansible task once we see the behavior in practice.
  run = true

  # Container Manager package must be installed first (sub-PR 2 / commit
  # ccf3066). Explicit depends_on so a fresh-state `tofu apply` orders this
  # correctly.
  depends_on = [synology_core_package.container_manager]
}
