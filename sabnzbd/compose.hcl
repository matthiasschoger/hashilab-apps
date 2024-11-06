job "sabnzbd" {
  datacenters = ["dmz"]
  type        = "service"

  group "sabnzbd" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "sabnzbd"

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
        "traefik.http.routers.sabnzbd.rule=Host(`sabnzbd.lab.schoger.net`)",
        "traefik.http.routers.sabnzbd.entrypoints=websecure"
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

#      user = "1026:100" 
    
      config {
        image = "linuxserver/sabnzbd:latest"

        volumes = [ 
          "/servarr/media:/media",
          "/servarr/downloads:/downloads"
        ]      
      }

      env {
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 512
        cpu    = 200
      }

      volume_mount {
        volume      = "sabnzbd"
        destination = "/config"
      }

      volume_mount {
        volume      = "servarr"
        destination = "/servarr"
      }
    }

    volume "sabnzbd" {
      type            = "csi"
      source          = "sabnzbd"
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