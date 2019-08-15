job "sql-tpch-data-update" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"

  group "sqltpch_dup_svc" {
    count = 1

    task "sqltpch_dup_dkr" {
      driver = "docker"

      config {
        image = "registry.service.consul/xcalar-qa/sql-tpch-data-update:latest"

        volumes = [
          "/netstore/qa/jenkins/SqlScaleTest:/netstore/qa/jenkins/SqlScaleTest"
        ]
      }

      service {
        name = "sql-tpch-data-update"
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
