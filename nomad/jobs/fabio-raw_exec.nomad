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
        command = "fabio-1.5.10-go1.11.1-linux_amd64"
      }

      artifact {
        source = "http://repo.xcalar.net/deps/fabio-1.5.10-go1.11.1-linux_amd64.tar.gz"

        options {
          checksum = "sha256:ea0d9f2c796bbbf030fb95cd6ee9ce17b7d37b1001f4bc6f26d7417843edaa03"
        }
      }

      resources {
        cpu    = 200
        memory = 128

        network {
          port "http" {
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
