job "adguard" {
  datacenters = ["home"]
  type        = "service"

  group "adguard" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      port "http" { to = 80 }
      port "dns" { to = 53 }
    }

    task "server" {


      service {
        name = "adguard-dns"

        port = "dns"

        check {
          type     = "tcp"
          interval = "5s"
          timeout  = "5s"
        }
      }

      service {
        name = "adguard-ui"

        port = "http"

        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "5s"
        }

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.adguard.rule=Host(`adguard.lab.schoger.net`)",
          "traefik.http.routers.adguard.entrypoints=websecure"
        ]
      }

      driver = "docker"

      config {
        image = "adguard/adguardhome:latest"

        ports = ["http","dns"]
      }

      env {
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 80
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