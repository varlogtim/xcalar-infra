job "gocd_agent" {
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    stagger      = "10s"
    max_parallel = 1
  }

  group "gocd_agent" {
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

    task "gocd_agent" {
      driver = "docker"

      config {
        image = "gocd/gocd-agent-centos-7:v19.12.0"

        #args = [ "-e", ]

        dns_search_domains = ["int.xcalar.com"]
        dns_servers        = ["${NOMAD_IP_cnc}:8600", "10.10.2.136", "10.10.6.32"]
        volumes = [
          "./local:/godata",
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        env         = true
        destination = "secret/gocd.env"

        data = <<EOT
GO_SERVER_URL="https://gocd.service.consul/go"
EOT
      }

      resources {
        cpu    = 1000
        memory = 1000

        network {
          port "cnc" {}
        }
      }

      env {
        "GOCD_PLUGIN_INSTALL_docker-elastic-agents" = "https://github.com/gocd-contrib/docker-elastic-agents/releases/download/v3.0.0-222/docker-elastic-agents-3.0.0-222.jar"
        "GO_SERVER_URL"                             = "https://gocd.service.consul/go"
      }
    }
  }
}
