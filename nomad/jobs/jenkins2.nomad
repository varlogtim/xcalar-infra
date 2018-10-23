job "jenkins2" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"
  priority    = 50

  update {
    stagger      = "10s"
    max_parallel = 1
  }

  group "jenkins-master" {
    count = 1

    restart {
      attempts = 10
      interval = "5m"
      delay    = "25s"
      mode     = "delay"
    }

    task "jenkins-master" {
      driver = "docker"

      config {
        image = "jenkins/jenkins:lts"

        port_map {
          http = 8080
          jnlp = 50000
        }

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
          "/netstore/infra/jenkins2:/var/jenkins_home",
        ]
      }

      service {
        name = "jenkins-master"
        tags = ["global", "jenkins", "master"]
        port = "http"

        check {
          name     = "alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = 8000
        memory = 4096

        network {
          mbits = 10

          port "http" {
            static = 8080
          }

          port "jnlp" {
            static = 50000
          }
        }
      }

      logs {
        max_files     = 10
        max_file_size = 15
      }

      kill_timeout = "60s"
    }
  }
}
