job "xcalar-3" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "10m"
    progress_deadline = "12m"
    auto_revert       = false
    canary            = 0
  }

  migrate {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "50s"
    healthy_deadline = "5m"
  }

  group "xcalar" {
    count = 1

    constraint {
      distinct_hosts = true
    }

    restart {
      attempts = 2
      interval = "30m"
      delay    = "15s"
      mode     = "fail"
    }

    #    ephemeral_disk {
    #      sticky  = true
    #      migrate = true
    #      size    = 8000
    #    }

    task "xce" {
      driver = "docker"

      config {
        image      = "registry.int.xcalar.com/xcalar/xcalar:1.4.1-2141.el7"
        force_pull = true

        port_map {
          monitor = 8000
          https   = 443
          engine  = 5000
          api     = 18552
        }

        privileged = true

        ulimit {
          nproc   = "50000"
          nofile  = "50000:50000"
          memlock = "-1:-1"
        }
      }

      env {
        MYSQL_PASSWORD      = "xcalar"
        MYSQL_ROOT_PASSWORD = "xcalar"
      }

      resources {
        cpu    = 24000
        memory = 16000

        network {
          mbits = 10
          port  "monitor"{}
          port  "https"{}
          port  "engine"{}
          port  "api" {}
        }
      }

      service {
        name = "comm"
        tags = ["xcalar"]
        port = "https"

        check {
          name     = "alive"
          type     = "tcp"
          interval = "120s"
          timeout  = "60s"
        }
      }

      service {
        name = "monitor"
        tags = ["xcalar"]
        port = "monitor"
      }

      service {
        name = "engine"
        tags = ["xcalar"]
        port = "engine"
      }

      service {
        name = "api"
        tags = ["xcalar"]
        port = "api"
      }
    }
  }
}
