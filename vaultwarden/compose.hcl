variable "base_domain" {
  default = "missing.environment.variable"
}

job "vaultwarden" {
  datacenters = ["dmz"]
  type        = "service"

  group "vaultwarden" {

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
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.vaultwarden.rule=Host(`bitwarden.${var.base_domain}`)",
        "dmz.http.routers.vaultwarden.entrypoints=cloudflare"
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9102"
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 50
            memory = 48
          }
        }
      }
    }

    task "server" {

      driver = "docker"

      user = "1026:100" # matthias:users

      config {
        image = "vaultwarden/server:latest"
      }

      env {
        TZ = "Europe/Berlin"

        ROCKET_PROFILE = "release"
        ROCKET_PORT = "80"
        WEBSOCKET_ENABLED = true
        LOG_LEVEL = "warn"
        DOMAIN = "https://bitwarden.${var.base_domain}"
      }

      resources {
        memory = 128
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
