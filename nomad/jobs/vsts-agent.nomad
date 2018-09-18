job "my-vsts-agents" {
  datacenters = ["xcalar-sjc"]

  group "vsts" {
    count = 2

    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    task "vsts-agent" {
      driver = "docker"

      config {
        image = "microsoft/vsts-agent:ubuntu-14.04-docker-17.12.0-ce-standard"

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }

      env {
        VSTS_ACCOUNT = "xcalar"
        VSTS_TOKEN   = "2tucq3pofi24pjdteaemt57xge7amkrbdyodoxbs6oggtkzkfxaa"
      }

      resources {
        memory = 8192
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

