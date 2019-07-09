job "registryv2" {
  region      = "global"
  datacenters = ["xcalar-sjc"]
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time  = "10s"
    healthy_deadline  = "3m"
    progress_deadline = "10m"
    auto_revert       = false
    canary            = 0
  }

  migrate {
    max_parallel     = 1
    health_check     = "checks"
    min_healthy_time = "10s"
    healthy_deadline = "5m"
  }

  group "registry" {
    count = 3

    constraint {
      operator = "distinct_hosts"
      value    = "true"
    }

    restart {
      attempts = 5
      interval = "5m"
      delay    = "15s"
    }

    task "registry" {
      driver = "docker"

      config {
        image      = "registry:2"
        force_pull = false

        volumes = [
          "/netstore/infra/registry/_data:/var/lib/registry",
          "local/config.yml:/etc/docker/registry/config.yml",
        ]

        port_map {
          image = 5000
        }
      }

      template {
        destination = "local/config.yml"

        data = <<EOD
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: redis
  filesystem:
    rootdirectory: /var/lib/registry
redis:
  addr: {{range $i, $e := service "redis" "any"}}{{$e.Address}}:{{$e.Port}}{{end}}
  db: 15
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOD
      }

      resources {
        memory = 500
        cpu    = 1000

        network {
          port "image" {}
        }
      }

      service {
        name = "registry"

        tags = [
          "urlprefix-registry.service.consul:9999/",
          "urlprefix-registry.service.consul:443/",
          "urlprefix-registry.int.xcalar.com:443/",
        ]

        port = "image"

        check {
          type     = "tcp"
          interval = "20s"
          timeout  = "10s"
        }
      }
    }
  }
}
