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
        command = "fabio-1.5.11-go1.11.5-linux_amd64"
      }

      artifact {
        source = "http://repo.xcalar.net/deps/fabio-1.5.11-go1.11.5-linux_amd64.tar.gz"

        options {
          checksum = "sha256:5d39fbd083f9cfdccead4abd16c4506e68a73c9d49cf9c8740a6e2ca012af200"
        }
      }

      resources {
        cpu    = 500
        memory = 256

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
