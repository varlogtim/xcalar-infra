job "sql-performance-grafana-datasource" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"

  group "sqlperf_ds_svc" {
    count = 1

    task "sqlperf_ds_dkr" {
      driver = "docker"

      config {
        image = "registry.service.consul/xcalar-qa/sql-tpch-grafana-datasource:latest"

        port_map {
          http = 80
        }

        volumes = [
          "/netstore/qa/jenkins/SqlScaleTest:/netstore/qa/jenkins/SqlScaleTest"
        ]
      }

      service {
        name = "sql-performance-grafana-datasource"
        port = "http"
        tags = ["urlprefix-sql-performance-grafana-datasource.service.consul:9999/"]

        check {
          name     = "alive"
          type     = "http"
          path     = "/"
          interval = "60s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 500 # 500MHz
        memory = 200 # 200MB
        network {
          port "http" {}
        }
      }

      logs {
        max_file_size = 15
      }

      kill_timeout = "120s"
    }
  }
}
