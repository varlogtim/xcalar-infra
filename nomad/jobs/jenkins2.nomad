job "jenkins2" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"
  priority    = 50

  constraint {
    distinct_hosts = true
  }

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
          ssh  = 22022
        }

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
          "/netstore/infra/jenkins2:/var/jenkins_home",
        ]
      }

      service {
        name = "http"
        port = "http"

        tags = ["global", "jenkins-master"]

        check {
          name     = "alive"
          type     = "tcp"
          interval = "60s"
          timeout  = "5s"
        }
      }

      service {
        name = "ssh"
        port = "ssh"
      }

      service {
        name = "jnlp"
        port = "jnlp"
      }

      resources {
        cpu    = 8000
        memory = 8000

        network {
          port "http" {
            static = 8080
          }

          port "jnlp" {
            static = 50000
          }

          port "ssh" {
            static = 22022
          }
        }
      }

      logs {
        max_file_size = 15
      }

      kill_timeout = "120s"
    }
  }
}
