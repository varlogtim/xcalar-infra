job "fabio" {
  datacenters = ["xcalar-sjc"]
  type        = "system"

  group "fabio" {
    count = 1

    task "fabio" {
      driver = "raw_exec"

      artifact {
        source = "https://storage.googleapis.com/repo.xcalar.net/deps/fabio-1.5.10-go1.11.1-linux_amd64"

        options {
          checksum = "sha256:9d9385372ae893c494ebe609681f90f36edf0a7af7042c17237e2c2ec6abc0c2"
        }
      }

      config {
        command = "fabio-1.5.10-go1.11.1-linux_amd64"
      }

      resources {
        cpu    = 100 # 500 MHz
        memory = 128 # 256MB

        network {
          port "http" {
            static = 9999
          }

          port "admin" {
            static = 9998
          }
        }
      }
    }
  }
}
