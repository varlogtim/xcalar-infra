job "my-vsts-agents" {
  datacenters = ["xcalar-sjc"]

  group "vsts" {
    count = 1

    restart {
      attempts = 5
      interval = "2m"
      delay    = "15s"
      mode     = "fail"
    }

    reschedule {
      attempts       = 15
      interval       = "1h"
      delay          = "30s"
      delay_function = "exponential"
      max_delay      = "120s"
      unlimited      = false
    }

    constraint {
      distinct_hosts = true
    }

    constraint {
      attribute    = "${meta.cluster}"
      set_contains = "newton"
    }

    task "vsts-agent" {
      driver = "docker"

      config {
        image = "mcr.microsoft.com/azure-pipelines/vsts-agent:ubuntu-14.04-docker-17.12.0-ce-standard"

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      template {
        data = <<EOT
        VSTS_ACCOUNT = "xcalar"
        VSTS_TOKEN   = "{{ with secret/data/infra/vsts }}{{ .Data.data.token }}"
EOT

        env         = true
        destination = "secrets/vsts.env"
      }

      resources {
        memory = 4096
        cpu    = 8000
      }
    }
  }
}

# resources {
#   memory = 500
#   network {
#     port "ipc" {
#       static = "8020"
#     }
#     port "ui" {
#       static = "50070"
#     }
#   }
# }
# service {
#   name = "hdfs"
#   port = "ipc"
# }
# config {
#   command = "bash"
#   args = [ "-c", "hdfs namenode -format && exec hdfs namenode -D fs.defaultFS=hdfs://${NOMAD_ADDR_ipc}/ -D dfs.permissions.enabled=false" ]
#   network_mode = "host"
#   port_map {
#     ipc = 8020
#     ui = 50070
#   }
# }

