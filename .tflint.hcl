# tflint config for the OpenTofu layer. We run ONLY the bundled "terraform"
# ruleset (language best-practices: naming, unused declarations, deprecated
# syntax, required versions) — it needs no `tflint --init` / network in CI.
#
# Provider-specific rulesets (authentik/synology/grafana/openbao) are
# deliberately NOT enabled: most aren't published as tflint plugins, and the
# providers here are community ones. `tofu fmt` (via treefmt) + `tofu validate`
# cover the rest.
config {
  call_module_type = "all"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
