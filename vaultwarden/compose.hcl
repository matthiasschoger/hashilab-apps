job "vaultwarden" {
  datacenters = ["home"]
  type        = "service"

  group "vaultwarden" {

    constraint {       # deploy to DMZ nodes
      attribute = "${node.class}"
      value     = "dmz"
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
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.vaultwarden.rule=Host(`bitwarden.schoger.net`)",
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

    // NOTE: This service is running in my DMZ and using a specific volume for DMZ services. 
    //  If you like to run this normally, just point the volume to the right location.
    task "server" {

      driver = "docker"

      user = "1026:100" # matthias:users

      config {
        image = "vaultwarden/server:latest"
      }

      env {
        ROCKET_PROFILE = "release"
        ROCKET_PORT = "80"
        WEBSOCKET_ENABLED = true
        LOG_LEVEL = "warn"
        DOMAIN = "https://bitwarden.schoger.net"
        TZ = "Europe/Berlin"
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
