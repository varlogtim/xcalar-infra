job "coverage-grafana-datasource" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"

  group "cvg_ds_svc" {
    count = 1

    task "cvg_ds_dkr" {
      driver = "docker"

      config {
        image = "registry.service.consul/xcalar-qa/coverage-grafana-datasource:latest"

        port_map {
          http = 80
        }

        volumes = [
          "/netstore/qa/coverage:/netstore/qa/coverage"
        ]
      }

      service {
        name = "coverage-grafana-datasource"
        port = "http"

        check {
          name     = "alive"
          type     = "http"
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
