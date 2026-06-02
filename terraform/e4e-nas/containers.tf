# Container Manager (Docker) workloads on e4e-nas.
#
# `synology_container_project` is a Docker Compose project managed via the DSM
# API — mirror the patterns in nix/docker-compose/ where possible. Resource
# schema: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/container_project
#
# Template below is COMMENTED OUT — uncomment and verify field names against the
# resource docs (the provider's compose schema evolves between releases).

# resource "synology_container_project" "example" {
#   name = "example"
#   # The project's working dir lives under a shared folder on the NAS:
#   share_path = "/projects/example"
#
#   # Compose content. Keep the source compose file in this repo and load it:
#   services = yamldecode(file("${path.module}/compose/example.yml")).services
#
#   run = true
# }
