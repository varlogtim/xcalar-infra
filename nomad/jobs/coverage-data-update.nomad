job "coverage-data-update" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"

  group "cvg_dup_svc" {
    count = 1

    task "cvg_dup_dkr" {
      driver = "docker"

      config {
        image = "registry.service.consul/xcalar-qa/coverage-data-update:latest"

        volumes = [
          "/netstore/qa/coverage:/netstore/qa/coverage"
        ]
      }

      service {
        name = "coverage-data-update"
        check {
          name     = "alive"
          type     = "tcp"
          interval = "60s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 500 # 500MHz
        memory = 200 # 200MB
      }

      logs {
        max_file_size = 15
      }

      kill_timeout = "120s"
    }
  }
}
