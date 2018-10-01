job "amit-xcalar-1" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  #  update {
  #    max_parallel      = 1
  #    min_healthy_time  = "30s"
  #    healthy_deadline  = "10m"
  #    progress_deadline = "12m"
  #    auto_revert       = false
  #    canary            = 0
  #  }
  #
  #  migrate {
  #    max_parallel     = 1
  #    health_check     = "checks"
  #    min_healthy_time = "50s"
  #    healthy_deadline = "5m"
  #  }

  constraint {
    distinct_hosts = true
  }
  constraint {
    attribute = "${meta.cluster}"
    value     = "newton"
  }
  group "xcalar_cluster" {
    count = 3

    restart {
      attempts = 5
      interval = "2m"
      delay    = "15s"
      mode     = "fail"
    }

    ephemeral_disk {
      sticky  = true
      migrate = false
      size    = 8000
    }

    task "xcalar" {
      driver = "docker"

      config {
        image = "registry.int.xcalar.com/xcalar/xcalar:1.4.1-2141.el7"

        port_map {
          monitor = 8000
          https   = 443
          api     = 18552
          comms   = 5000
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
        cpu    = 18000
        memory = 16000

        network {
          mbits = 1
          port  "monitor"{}
          port  "https"{}
          port  "api" {}
          port  "comms"{}
        }
      }

      service {
        name = "xcalar"
        tags = ["xcalar"]
        port = "https"

        check {
          name     = "alive"
          type     = "tcp"
          interval = "120s"
          timeout  = "60s"
        }
      }
    }
  }
}
