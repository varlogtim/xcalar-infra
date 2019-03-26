job "fabio" {
  datacenters = ["xcalar-sjc"]
  type        = "system"

  update {
    stagger      = "5s"
    max_parallel = 1
  }

  group "fabio" {
    restart {
      attempts = 3
      delay    = "30s"
      interval = "3m"
      mode     = "fail"
    }

    task "fabio" {
      driver = "docker"

      config {
        image        = "fabiolb/fabio"
        network_mode = "host"
        force_pull   = true

        args = ["-registry.consul.addr=${NOMAD_IP_lb}:8500"]
      }

      resources {
        cpu    = 500
        memory = 250

        network {
          port "lb" {
            static = 9999
          }

          port "ui" {
            static = 9998
          }
        }
      }
    }
  }
}
