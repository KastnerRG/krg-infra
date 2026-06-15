resource "grafana_data_source" "prometheus" {
  name       = "Prometheus"
  is_default = true
  type       = "prometheus"
  uid        = "de0e1fh1fk35sc"
  url        = "http://prometheus:9090"

  json_data_encoded = jsonencode({
    httpMethod     = "POST"
    prometheusType = "Prometheus"
  })
}

# Loki — Alloy ships /var/log + the journal here (compose.grafana.yml), but until
# now no Loki datasource was registered, so logs were invisible in Grafana. Grafana
# reaches loki:3100 over the krg-prod project's default network. UID is pinned so
# the LogQL dashboard (dashboards/logs.json) references it deterministically.
resource "grafana_data_source" "loki" {
  name = "Loki"
  type = "loki"
  uid  = "krg-loki-ds"
  url  = "http://loki:3100"
}
