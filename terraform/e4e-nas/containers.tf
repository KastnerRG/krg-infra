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
# Learned the hard way 2026-06-02 — one of the three provider bugs that drove
# the Garage retreat. See docs/adr/0007-dsm-config-ansible-not-terraform.md
# (the "Garage retreat" section captures all three bugs and why we moved
# Garage itself to Ansible; this file only keeps the FileStation-folder
# resources, which are a general DSM constraint, not a Garage-specific one).

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

# Compose project working dir. The Ansible `synology_garage` role drops
# garage.toml in here; terraform-registering the folder via FileStation means
# the role can rely on its existence + index-visibility without a `sudo
# mkdir` workaround.
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
# Garage's container project + cluster bootstrap + config are NOT managed
# here — they live in the `synology_garage` Ansible role under
# ansible/synology/roles/. Per ADR 0007 (provider-maturity-gated split):
# `synology_container_project` hit three distinct upstream bugs in one
# session (#110 secrets.content not sensitive, #113 FileStation index
# instability, #114 JSON parser bombs on docker-compose's streamed output),
# which is exactly the empirical signal that pushes a surface to the
# Ansible side of the line.
#
# What stays here: the three FileStation-tracked dirs above (/docker/garage,
# /s3-data/meta, /s3-data/data) — those work, and the FileStation index
# requirement is a general DSM constraint that applies to anything we deploy
# on the NAS, not just Garage.
