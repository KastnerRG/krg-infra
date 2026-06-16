# Dashboards are authored as raw Grafana JSON under dashboards/ and applied
# verbatim. They all target the pinned Prometheus datasource UID from
# datasources.tf (de0e1fh1fk35sc), so the JSON references resolve on apply.
#
# for_each over the directory so a new dashboards/*.json is picked up with no
# extra HCL. The map key (filename) is the Terraform resource address.
resource "grafana_dashboard" "krg" {
  for_each    = fileset("${path.module}/dashboards", "*.json")
  config_json = file("${path.module}/dashboards/${each.value}")
}

# Migrate the previously single-resource waiter dashboard into the for_each map so
# the apply updates it in place (same UID) instead of destroy+recreate.
moved {
  from = grafana_dashboard.krg_waiter
  to   = grafana_dashboard.krg["krg-waiter.json"]
}
