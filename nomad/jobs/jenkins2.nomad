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
    task "jenkins-docker-sidecar" {
      driver = "docker"


    task "jenkins-master" {
      driver = "docker"

      config {
        image = "jenkins/jenkins:2.150.3"

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
        name = "jenkins"
        port = "http"

        tags = ["jenkins2", "urlprefix-jenkins2.service.consul:9999/", "urlprefix-jenkins2.nomad:9999/", "urlprefix-jenkins2.int.xcalar.com:9999/", "urlprefix-jenkins2:9999/"]

        check {
          name     = "alive"
          type     = "tcp"
          interval = "60s"
          timeout  = "5s"
        }
      }

      service {
        name = "jenkins-ssh"
        port = "ssh"

        tags = ["ssh"] #, "urlprefix-:22022 proto=tcp"]

        check {
          name     = "alive"
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }

      service {
        name = "jenkins-jnlp"
        port = "jnlp"

        tags = ["jnlp"] #, "urlprefix-:22022 proto=tcp"]

        check {
          name     = "alive"
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 8000
        memory = 8000

        network {
          port "http" {
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
