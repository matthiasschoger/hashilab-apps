variable "base_domain" {
  default = "missing.environment.variable"
}

job "adguard" {
  datacenters = ["home"]
  type        = "service"

  group "adguard" {

    network {
      mode = "bridge"

      port "dns" { to = 53 }

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "adguard-ui"

      port = 80

      check {
        type     = "http"
        path     = "/login.html"
        interval = "10s"
        timeout  = "5s"
        expose   = true
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.adguard.rule=Host(`adguard.lab.${var.base_domain}`)",
        "traefik.http.routers.adguard.entrypoints=websecure"
      ]

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" 
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

      service {
        name = "adguard-dns"

        port = "dns"
      }

      driver = "docker"

      config {
        image = "adguard/adguardhome:latest"

        ports = ["dns"]
      }

      env {
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 128
        cpu    = 50
      }

      volume_mount {
        volume      = "adguard"
        destination = "/opt/adguardhome/conf"
      }
    }

    volume "adguard" {
      type            = "csi"
      source          = "adguard"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}