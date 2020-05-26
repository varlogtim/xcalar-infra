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
      interval = "3m"
      delay    = "15s"
      mode     = "delay"
    }

    ephemeral_disk {
      size = 300
    }

    task "gocd_agent" {
      driver = "docker"

      config {
        image = "gocd/gocd-agent-centos-7:v20.3.0"

        #args = [ "-e", ]

        dns_search_domains = ["int.xcalar.com"]
        dns_servers        = ["10.10.2.136", "10.10.6.32"]
        volumes = [
          "/netstore:/netstore",
          "./local:/godata",
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        env         = true
        destination = "secrets/gocd.env"

        data = <<EOT
{{ range service "gocd" }}
GO_SERVER_URL=https://{{ .Address }}{{ end }}:8154/go
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
        "GOCD_PLUGIN_INSTALL_docker-elastic-agents" = "https://github.com/gocd-contrib/docker-elastic-agents/releases/download/v3.1.0-248-exp/docker-elastic-agents-3.1.0-248.jar"
        "AGENT_BOOTSTRAPPER_ARGS"                   = "-sslVerificationMode NONE"
      }
    }
  }
}
