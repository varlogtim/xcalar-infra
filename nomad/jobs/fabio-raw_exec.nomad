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
      driver = "raw_exec"

      config {
        command = "fabio-1.5.13-go1.13.4-linux_amd64"

        args = ["-insecure", "-cfg", "local/fabio.properties"]
      }

      vault {
        policies = ["fabiolb"]
        env      = true
      }

      template {
        destination = "local/fabio.properties"
        change_mode = "restart"

        data = <<EOT
registry.consul.addr = {{ env "NOMAD_IP_lb" }}:8500
proxy.cs = cs=vault-pki;type=vault-pki;cert=xcalar_ca/issue/int-xcalar-com;refresh=24h
proxy.addr = :{{ env "NOMAD_PORT_http" }},:{{ env "NOMAD_PORT_lb" }},:{{ env "NOMAD_PORT_ssl" }};cs=vault-pki;tlsmin=tls12;tlsmax=tls12

#registry.consul.register.enabled = false
EOT
      }

      artifact {
        source = "http://repo.xcalar.net/deps/fabio-1.5.13-go1.13.4-linux_amd64.tar.gz"

        options {
          checksum = "sha256:39983bfda3a211cb42dda9301cf7febd683104de16b27667dc091da883c8906a"
        }
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
            static = 443
          }

          port "http" {
            static = 80
          }
        }
      }
    }
  }
}
