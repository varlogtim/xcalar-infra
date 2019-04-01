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
        force_pull   = false

        args = ["-cfg", "/local/fabio.properties"]
      }

      vault {
        policies = ["fabiolb"]
        env      = true
      }

      template {
        data = <<EOT
registry.consul.addr = {{ env "NOMAD_IP_lb" }}:8500

proxy.cs = cs=vaultcs;type=vault-pki;cert=xcalar_ca/issue/int-xcalar-com

proxy.addr = :{{ env "NOMAD_PORT_ssl" }};cs=vaultcs,\
             :{{ env "NOMAD_PORT_lb" }};proto=http
EOT

        destination = "local/fabio.properties"
        change_mode = "restart"
      }

      env {
        VAULT_ADDR = "https://vault.service.consul:8200"
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

          port "ssl" {
            static = 9443
          }
        }
      }
    }
  }
}
