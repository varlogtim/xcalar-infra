job "prometheus" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  constraint {
    attribute    = "${meta.localstore}"
    set_contains = "ssd"
  }

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
      mode     = "fail"
    }

    ephemeral_disk {
      size   = "300"
      sticky = true
    }

    task "loki" {
      driver = "docker"

      config {
        image = "grafana/loki:master"

        force_pull = true

        args = ["-config.file=/etc/loki/local-config.yaml"]
      }

      resources {
        network {
          port "loki_ui" {
            static = "3100"
          }
        }

        cpu    = 7000
        memory = 128
      }

      service {
        name = "loki-ui"
        port = "loki_ui"

        tags = ["urlprefix-loki-ui.nomad:9999/", "urlprefix-loki-ui.service.consul:9999/"]

        check {
          name     = "loki_ui port alive"
          type     = "tcp"
          interval = "20s"
          timeout  = "5s"
        }
      }
    }

    task "grafana" {
      driver = "docker"

      config {
        image = "grafana/grafana:master"

        force_pull = true

        port_map {
          grafana_ui = 3000
        }

        volumes = [
          #"/netstore/infra/grafana-ui/nomad/tmp:/tmp/grafana",
          "/netstore/infra/grafana-ui/nomad/var/lib/grafana:/var/lib/grafana",

          "/netstore/infra/grafana-ui/nomad/etc/grafana:/etc/grafana",
        ]
      }

      resources {
        network {
          port "grafana_ui" {}
        }

        cpu    = 6000
        memory = 128
      }

      service {
        name = "grafana"
        port = "grafana_ui"

        tags = [
          "urlprefix-grafana.nomad:9999/",
          "urlprefix-grafana.service.consul:9999/",
          "urlprefix-grafana.service.consul:443/",
          "urlprefix-grafana.int.xcalar.com:443/",
        ]

        check {
          name     = "grafana_ui port alive"
          type     = "http"
          path     = "/api/health"
          interval = "20s"
          timeout  = "5s"
        }
      }
    }

    task "pushgateway" {
      driver = "docker"

      config {
        image      = "prom/pushgateway:latest"
        force_pull = true

        volumes = [
          "/mnt/data/prometheus:/prometheus",
        ]

        args = ["--persistence.file=/prometheus/${NOMAD_JOB_NAME}-${NOMAD_GROUP_NAME}-${NOMAD_TASK_NAME}.pushgw"]

        port_map {
          pushgateway_ui = 9091
        }
      }

      resources {
        cpu    = 200
        memory = 100

        network {
          port "pushgateway_ui" {
            static = "9091"
          }
        }
      }

      service {
        name = "pushgateway-ui"
        port = "pushgateway_ui"

        tags = [
          "urlprefix-pushgateway-ui.nomad:9999/",
          "urlprefix-pushgateway-ui.service.consul:9999/",
          "urlprefix-pushgateway.service.consul:9999/",
          "urlprefix-pushgateway.service.consul:443/",
        ]

        check {
          name     = "pushgateway_ui port alive"
          type     = "tcp"
          interval = "20s"
          timeout  = "5s"
        }
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image = "prom/prometheus:v2.9.2"

        # force_pull = true

        volumes = [
          "local/prometheus.yml:/etc/prometheus/prometheus.yml",
          "/mnt/data/prometheus:/prometheus",
        ]
        port_map {
          prometheus_ui = 9090
        }
      }

      resources {
        cpu    = 4000
        memory = 1024

        network {
          port "prometheus_ui" {}
        }
      }

      service {
        name = "prometheus"
        port = "prometheus_ui"

        tags = [
          "urlprefix-prometheus.service.consul:9999/",
          "urlprefix-prometheus.nomad:9999/",
          "urlprefix-prometheus.service.consul:443/",
          "urlprefix-prometheus.int.xcalar.com:443/",
        ]

        check {
          name     = "prometheus_ui port alive"
          type     = "http"
          path     = "/-/healthy"
          interval = "20s"
          timeout  = "5s"
        }
      }

      template {
        change_mode   = "signal"
        change_signal = "SIGHUP"
        destination   = "local/prometheus.yml"

        data = <<EOH
---
global:
  scrape_interval: 10s
  scrape_timeout: 5s
  evaluation_interval: 10s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
  - job_name: pushgateway
    params:
      format:
        - prometheus
    metrics_path: /metrics
    honor_labels: true
    static_configs:
      - targets:
          - '{{ env "NOMAD_IP_pushgateway_ui" }}:9091'
  - job_name: loki
    metrics_path: /metrics
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: '{{ env "NOMAD_IP_prometheus_ui" }}:8500'
        datacenter: xcalar-sjc
        services: ["loki-ui"]
  - job_name: node-exporter
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: '{{ env "NOMAD_IP_prometheus_ui" }}:8500'
        datacenter: xcalar-sjc
        services: ["node-exporter"]
  - job_name: nomad
    metrics_path: /v1/metrics
    params:
      format:
        - prometheus
    consul_sd_configs:
      - server: '{{ env "NOMAD_IP_prometheus_ui" }}:8500'
        datacenter: xcalar-sjc
        services:
          - nomad
          - nomad-client
    relabel_configs:
    - source_labels: ['__meta_consul_tags']
      regex: '(.*)http(.*)'
      action: keep

EOH
      }
    }
  }
}

#    relabel_configs:
#      - source_labels:
#          - __meta_consul_tags
#        regex: .*,http,.*
#        action: keep
#  - job_name: nomad_metrics
#    scrape_interval: 5s
#    metrics_path: /v1/metrics
#    params:
#      format:
#        - prometheus
#    consul_sd_configs:
#      - server: '{{ env "NOMAD_IP_prometheus_ui" }}:8500'
#        datacenter: xcalar-sjc
#        scheme: http
#        services:
#          - nomad-client
#          - nomad
#    tls_config:
#      insecure_skip_verify: true
#    relabel_configs:
#      - source_labels:
#          - __meta_consul_tags
#        separator: ;
#        regex: (.*)http(.*)
#        replacement: $1
#        action: keep
#      - source_labels:
#          - __meta_consul_address
#        separator: ;
#        regex: (.*)
#        target_label: __meta_consul_service_address
#        replacement: $1
#        action: replace

