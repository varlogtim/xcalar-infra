job "jenkins_swarm" {
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
  group "swarm" {
    count = 2
    constraint {
      distinct_hosts = true
    }
    constraint {
      attribute = "${node_class}"
      operator  = "set_contains"
      value     = "jenkins_slave"
    }
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }
    #    ephemeral_disk {
    #      sticky  = true
    #      migrate = true
    #      size    = 20000
    #    }
    #    task "decode" {
    #      vault {
    #        policies = ["jenkins_slave"]
    #      }
    #
    #      driver = "exec"
    #
    #      config {
    #        command = "/bin/bash"
    #        args    = ["-c", "/usr/local/bin/vault kv get -field=password secret/roles/jenkins-slave/swarm > secrets/swarm_pass"]
    #      }
    #    }
    #
    task "worker" {
      driver = "java"
      resources {
        cpu    = 8000  # MHz
        memory = 16048 # MB
      }
      config {
        jar_path    = "local/swarm-client-3.14.jar"
        jvm_options = ["-Xmx2048m", "-Xms256m"]
        args = [
          "-master",
          "https://jenkins.int.xcalar.com/",
          "-sslFingerprints",
          "D7:F9:76:25:B2:7D:E9:00:59:00:9B:CD:CE:6B:5F:97:9E:2F:68:A3:79:13:FE:F6:43:9F:A7:D0:5B:AC:7F:78",
          "-executors",
          "1",
          "-labels",
          "${SWARM_TAGS}",
          "-mode",
          "exclusive",
          "-username",
          "swarm",
          "-passwordEnvVariable",
          "SWARM_PASS",
        ]
      }
      env {
        "SWARM_PASS" = "D7XmxQFAmqiN66vQtnmz6+bt"
        "SWAR_TAGS"  = "nomad debug"
      }
      # Specifying an artifact is required with the "java" driver. This is the
      # mechanism to ship the Jar to be run.
      artifact {
        source = "http://repo.xcalar.net/deps/swarm-client-3.14.jar"
        options {
          checksum = "sha256:d3bdef93feda423b4271e6b03cd018d1d26a45e3c2527d631828223a5e5a21fc"
        }
      }
    }
  }
}
