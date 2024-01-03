job "vaultwarden" {
  datacenters = ["home"]
  type        = "service"

  group "vaultwarden" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    restart {
      attempts = 3
      delay = "1m"
      mode = "fail"
    }

    network {
      mode = "bridge"

      port "envoy_metrics_ui" { to = 9102 }
      port "envoy_metrics_ls" { to = 9103 }
    }

    service {
      name = "vaultwarden-ui"

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
        "traefik.http.routers.vaultwarden.entrypoints=inet-websecure"
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_ui}" # make envoy metrics port available in Consul
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

    # LiveSync, see https://www.blackvoid.club/bitwarden-livesync-feature/
    service {
      name = "vaultwarden-livesync"

      port = 81

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.vaultwarden-livesync.rule=Host(`bitwarden.schoger.net`) && (Path(`/notifications/hub`) && !Path(`/notifications/hub/negotiate`))",
        "traefik.http.routers.vaultwarden-livesync.entrypoints=inet-websecure"
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_ls}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
              envoy_prometheus_bind_addr = "0.0.0.0:9103"
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

        ports = ["http", "livesync"]
      }

      env {
        ROCKET_PROFILE = "release"
        ROCKET_PORT = "80"
        WEBSOCKET_PORT = "81"
        WEBSOCKET_ENABLED = true
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
