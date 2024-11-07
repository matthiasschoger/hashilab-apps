job "qbittorrent" {
  datacenters = ["dmz"]
  type        = "service"

  group "qbittorrent" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "qbittorrent"

      port = 8080

      # check {
      #   type     = "http"
      #   path     = "/"
      #   interval = "10s"
      #   timeout  = "2s"
      #   expose   = true # required for Connect
      # }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.qbittorrent.rule=Host(`qbittorrent.lab.schoger.net`)",
        "traefik.http.routers.qbittorrent.entrypoints=websecure"
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
            memory = 64
          }
        }
      }
    }

    task "server" {

      driver = "docker"

      config {
        image = "linuxserver/qbittorrent:latest"

        volumes = [
          "/servarr/downloads:/downloads"
        ]      
      }

      env {
        TZ = "Europe/Berlin"

        PUID = 1026
        PGID = 100
      }

      resources {
        memory = 512
        cpu    = 200
      }

      volume_mount {
        volume      = "qbittorrent"
        destination = "/config"
      }

      volume_mount {
        volume      = "servarr"
        destination = "/servarr"
      }
    }

    volume "qbittorrent" {
      type            = "csi"
      source          = "qbittorrent"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

    volume "servarr" {
      type            = "csi"
      source          = "servarr"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
  }
}