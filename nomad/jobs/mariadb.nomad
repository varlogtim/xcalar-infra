job "mariadb" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time  = "10s"
    healthy_deadline  = "3m"
    progress_deadline = "10m"
    auto_revert       = false
    canary            = 0
  }

  migrate {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "10s"
    healthy_deadline = "5m"
  }

  group "sql" {
    count = 1

    restart {
      attempts = 2
      interval = "30m"
      delay    = "15s"
      mode     = "fail"
    }

    ephemeral_disk {
      sticky  = true
      migrate = true
      size    = 300
    }

    task "mysql" {
      driver = "docker"

      config {
        image = "mariadb:5.5"

        port_map {
          db = 3306
        }
      }

      env {
        MYSQL_PASSWORD      = "xcalar"
        MYSQL_ROOT_PASSWORD = "xcalar"
      }

      resources {
        cpu    = 2000 # 500 MHz
        memory = 1200 # 256MB

        network {
          mbits = 10
          port  "db"  {}
        }
      }

      service {
        name = "mariadb"
        tags = ["global", "sql"]
        port = "db"

        check {
          name     = "alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
