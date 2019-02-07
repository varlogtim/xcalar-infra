job "prometheus" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = false
    canary           = 0
  }

  group "monitoring" {
    count = 1

    restart {
      attempts = 10
      interval = "5m"
      delay    = "25s"
      mode     = "delay"
    }

    ephemeral_disk {
      size    = "3000"
      sticky  = true
      migrate = true
    }

    task "grafana" {
      driver = "docker"

      config {
        image = "grafana/grafana:5.4.3"

        port_map {
          grafana_ui = 3000
        }

        volumes = [
          "/netstore/infra/grafana-ui/nomad/var/lib/grafana:/var/lib/grafana",
          "/netstore/infra/grafana-ui/nomad/etc/grafana:/etc/grafana",
        ]
      }

      resources {
        network {
          port "grafana_ui" {}
        }
      }

      service {
        name = "grafana-ui"
        port = "grafana_ui"

        tags = ["urlprefix-grafana-ui.nomad:9999/", "urlprefix-grafana-ui.service.consul:9999/"]

        check {
          name     = "grafana_ui port alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }

    task "prometheus" {
      template {
        change_mode = "restart"
        destination = "local/prometheus.yml"

        data = <<EOH
---
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    scrape_interval: 5s
    static_configs:
      - targets:
          - localhost:9090
  - job_name: node-exporter
    scrape_interval: 5s
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: 10.10.5.18:8500
        datacenter: xcalar-sjc
        services: ["node-exporter"]
  - job_name: nomad
    scrape_interval: 10s
    metrics_path: /v1/metrics
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: 10.10.5.18:8500
        datacenter: xcalar-sjc
        services:
          - nomad
          - nomad-client
    relabel_configs:
      - source_labels:
          - __meta_consul_tags
        regex: .*,http,.*
        action: keep
  - job_name: nomad_metrics
    scrape_interval: 5s
    metrics_path: /v1/metrics
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: 10.10.5.18:8500
        datacenter: xcalar-sjc
        scheme: http
        services:
          - nomad-client
          - nomad
    tls_config:
      insecure_skip_verify: true
    relabel_configs:
      - source_labels:
          - __meta_consul_tags
        separator: ;
        regex: (.*)http(.*)
        replacement: $1
        action: keep
      - source_labels:
          - __meta_consul_address
        separator: ;
        regex: (.*)
        target_label: __meta_consul_service_address
        replacement: $1
        action: replace
EOH
      }

      driver = "docker"

      config {
        image = "prom/prometheus:v2.7.1"

        volumes = [
          "local/prometheus.yml:/etc/prometheus/prometheus.yml",
        ]

        port_map {
          prometheus_ui = 9090
        }
      }

      resources {
        cpu    = 4000
        memory = 2048

        network {
          port "prometheus_ui" {}
        }
      }

      service {
        name = "prometheus-ui"
        port = "prometheus_ui"
        tags = ["urlprefix-prometheus-ui.nomad:9999/", "urlprefix-prometheus-ui.service.consul:9999/"]

        check {
          name     = "prometheus_ui port alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
