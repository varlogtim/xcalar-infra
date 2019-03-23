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
        image        = "fabiolb/fabio:1.5.11-go1.11.5"
        network_mode = "host"
        args         = ["-registry.consul.addr=127.0.0.1:8500"]
      }

      resources {
        cpu    = 200
        memory = 100

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
