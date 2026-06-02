# Container Manager (Docker) workloads on e4e-nas.
#
# `synology_container_project` = a Docker Compose project managed via the DSM
# Container Manager API. Schema:
#   https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/container_project
#
# IMPORTANT — use STRUCTURED `services` / `configs` / `networks` / `volumes`
# attributes, NOT the `content` string. The provider's content plan-modifier
# (UseSchemaForUnknownContent) silently rebuilds the YAML from the structured
# attributes — if you set `content =` alone, the provider plans `services: {}`
# (everything wiped) and errors with "planned value does not match config".
# Learned the hard way 2026-06-02; see the in-tree memory.

# --- FileStation-registered directories the container needs --------------
# The synology_container_project resource's create-time validation calls
# FileStation List on the project's share parent and bind-mount sources;
# DSM's FileStation API only sees directories that were CREATED through it
# (`sudo mkdir` on the shell creates the dir on disk but doesn't register
# it in the FileStation index). We hit this twice on 2026-06-02:
#
#   1. share_path "/docker/garage" → provider's Get errored
#      "Failed to create project share: result is empty" because List of
#      "/docker" returned files:[] even though the dir existed.
#   2. bind source "/volume2/s3-data/meta" → Docker errored "bind source
#      path does not exist" because the subdir was never created at all.
#
# synology_filestation_folder calls FileStation.CreateFolder, which both
# creates the dir on disk AND registers it in the index. Idempotent — a
# subsequent apply re-Gets and no-ops. Captures the "FileStation must know
# about dirs the provider touches" requirement in IaC so future operators
# don't get bit by the same gotcha.

# Compose project working dir. The operator-managed garage.toml lives in
# here (see README "Workloads → Garage"); terraform-registering this folder
# also satisfies the operator install step's FileStation.CreateFolder
# requirement, so a stray `sudo mkdir` workflow can't bypass the index.
resource "synology_filestation_folder" "docker_garage" {
  path = "/docker/garage"
}

# Garage's two state directories under the s3-data share. The share itself
# is spec'd in spec/e4e-nas/shares.yml (Btrfs, snapshots, browseable=false);
# the subdirectories Garage bind-mounts don't exist on a fresh NAS.
resource "synology_filestation_folder" "s3_data_meta" {
  path = "/s3-data/meta"
}

resource "synology_filestation_folder" "s3_data_data" {
  path = "/s3-data/data"
}

# --- Garage S3 object store (ADR 0002 + 0003) --------------------------------
# Single-node Garage cluster, data on /volume2/s3-data, image pinned.
#
# Secrets handling: this resource does NOT touch Garage secrets at all. The
# provider's nested string attrs (incl. `secrets.content` and
# `configs.content`) are NOT marked sensitive — they'd leak in plan output.
# `garage.toml` is an OPERATOR-MANAGED file at /volume1/docker/garage/
# garage.toml; this resource only bind-mounts it RO into the container. The
# README documents the operator workflow. Sub-PR 5 of #101 (`garage_config`
# Ansible role) supersedes the operator step with no_log + ansible-vault.
#
# After first `tofu apply`, the cluster needs ONE more operator one-shot
# (`garage layout assign` + `apply`) — README has the exact commands.
resource "synology_container_project" "garage" {
  name = "garage"

  # Compose project working dir on the NAS — under the `docker` share. This
  # is also where the operator-managed garage.toml lives (mounted below).
  share_path = "/docker/garage"

  services = {
    garage = {
      name           = "garage"
      image          = "dxflrs/garage:${var.garage_image_tag}"
      container_name = "garage"
      restart        = "unless-stopped"

      # Garage exposes 4 ports (3900 S3 API, 3901 RPC, 3902 web, 3903 admin).
      # Single-node needs no overlay; host networking is simplest. Sub-PR 4
      # adds DSM AppPortal reverse-proxy + Let's Encrypt for the public ones.
      network_mode = "host"

      volumes = [
        # Garage state — on the s3-data Btrfs share (snapshots per
        # spec/e4e-nas/snapshots.yml).
        {
          type   = "bind"
          source = "/volume2/s3-data/meta"
          target = "/var/lib/garage/meta"
        },
        {
          type   = "bind"
          source = "/volume2/s3-data/data"
          target = "/var/lib/garage/data"
        },
        # Operator-managed config file. MUST exist on the NAS before this
        # apply or the container will crash-loop. See README workflow.
        {
          type      = "bind"
          source    = "/volume1/docker/garage/garage.toml"
          target    = "/etc/garage.toml"
          read_only = true
        },
      ]

      environment = {
        RUST_LOG = "garage=info,garage_api=info,garage_block=info"
      }
    }
  }

  # Same upstream Run-field-dropped bug as core_package (ADR 0007 / #102's
  # package-state workaround). Container projects MAY also need a similar
  # post-apply nudge; investigate when we see live behavior. TODO if needed.
  run = true

  # Container Manager package must be installed first (commit ccf3066 / #102).
  # The bind-mount target directories must exist (FileStation-registered, not
  # just present on disk) before container creation — see the filestation_folder
  # resources above.
  depends_on = [
    synology_core_package.container_manager,
    synology_filestation_folder.docker_garage,
    synology_filestation_folder.s3_data_meta,
    synology_filestation_folder.s3_data_data,
  ]
}
