job "hashi-ui-1" {
  datacenters = ["xcalar-sjc"]
  region      = "global"

  group "hashi-ui" {
    task "hashi-ui" {
      driver = "docker"

      config {
        image = "jippi/hashi-ui"

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]

        port_map {
          http = 3000
        }
      }

      env {
        CONSUL_ENABLE          = "1"
        CONSUL_ADDR            = "consul-1.int.xcalar.com:8500"
        CONSUL_HTTP_SSL_VERIFY = "false"

        NOMAD_ENABLE = "1"
        NOMAD_ADDR   = "http://nomad-1.int.xcalar.com:4646"
      }

      resources {
        memory = 256
        cpu    = 3000

        network {
          port "http" {}
        }
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

