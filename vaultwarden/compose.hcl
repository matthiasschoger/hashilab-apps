job "vaultwarden" {
  datacenters = ["home"]
  type        = "service"

  group "vaultwarden" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "vaultwarden"

      port = 80

      check {
        type     = "http"
        path     = "/alive"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.vaultwarden.rule=Host(`bitwarden.schoger.net`)",
        "traefik.http.routers.vaultwarden.entrypoints=cloudflare"
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
            cpu    = 50
            memory = 96
          }
        }
      }
    }

    task "server" {

      driver = "docker"

      config {
        image = "vaultwarden/server:latest"
      }

      env {
        ROCKET_PROFILE = "release"
        ROCKET_PORT = "80"
        WEBSOCKET_ENABLED = true
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 200
        cpu    = 100
      }

      volume_mount {
        volume      = "vaultwarden"
        destination = "/data"
      }
    }
    
    volume "vaultwarden" {
      type            = "csi"
      source          = "vaultwarden"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
