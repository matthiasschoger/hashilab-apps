variable "base_domain" {
  default = "missing.environment.variable"
}

job "mealie" {
  datacenters = ["home"]
  type        = "service"

  group "mealie" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "mealie"

      port = 9000

      check {
        type     = "http"
        path     = "/api/app/about"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.mealie.rule=Host(`mealie.lab.${var.base_domain}`)"
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

      config {
        image = "ghcr.io/mealie-recipes/mealie"
      }

      env {
        TZ            = "Europe/Berlin"
        BASE_URL      = "https://mealie.lab.${var.base_domain}"
        ALLOW_SIGNUP  = "false"

        LOG_LEVEL     = "warning"
      }

      resources {
        memory = 512
        cpu    = 500
      }

      volume_mount {
        volume      = "mealie"
        destination = "/app/data"
      }
    }

    volume "mealie" {
      type            = "csi"
      source          = "mealie"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

  }
}