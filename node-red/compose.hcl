job "node-red" {
  datacenters = ["home"]
  type        = "service"

  group "node-red" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "node-red"

      port = 1880

      check {
        type     = "http"
        path     = "/auth/login"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.node-red.rule=Host(`node-red.lab.home`)",
        "traefik.http.routers.node-red.entrypoints=websecure"
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
              envoy_prometheus_bind_addr = "0.0.0.0:9102"
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 64
          }
        }
      }
    }

    task "server" {

      driver = "docker"

      config {
        image = "nodered/node-red:latest"

        ports = ["http"]
      }

      env {
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 200
        cpu    = 100
      }

      volume_mount {
        volume      = "node-red"
        destination = "/data"
      }
    }

    volume "node-red" {
      type            = "csi"
      source          = "node-red"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}