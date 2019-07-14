job "gocd" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    stagger      = "10s"
    max_parallel = 1
  }

  group "gocd" {
    count = 1

    restart {
      attempts = 10
      interval = "5m"
      delay    = "25s"
      mode     = "delay"
    }

    ephemeral_disk {
      size = 300
    }

    task "gocd_server" {
      driver = "docker"

      config {
        image = "gocd/gocd-server:v19.3.0"

        dns_search_domains = ["int.xcalar.com"]
        dns_servers        = ["${NOMAD_IP_ui}:8600", "10.10.2.136", "10.10.1.1"]

        port_map {
          ui = 8153
          db = 8154
        }

        volumes = [
          "/netstore/infra/gocd/data:/godata",
          "/netstore/infra/gocd/home:/home/go",
          "/var/run/docker:/var/run/docker.sock",
        ]
      }

      env {
        GOCD_PLUGIN_INSTALL_docker-elastic-agents = "https://github.com/gocd-contrib/docker-elastic-agents/releases/download/v0.8.0/docker-elastic-agents-0.8.0.jar"
      }

      resources {
        cpu    = 4000
        memory = 2000

        network {
          port "ui" {
            static = "8153"
          }

          port "db" {
            static = "8154"
          }
        }
      }

      service {
        name = "gocd"
        tags = ["urlprefix-gocd.service.consul:443/"]
        port = "ui"

        check {
          name     = "alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "4s"
        }
      }
    }
  }
}
