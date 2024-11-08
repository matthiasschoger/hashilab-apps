variable "base_domain" {
  default = "missing.environment.variable"
}

job "homeassistant" {
  datacenters = ["home"]
  type        = "service"

  group "homeassistant" {

    network {
#      mode = "bridge"

      port "http" { static = 8123 }
      port "shelly" { static = 5683 }    # reservation for Shelly port
      port "homekit" { static = 21063 }  # used by HomeKit
      port "mDNS" { static = 5353 }      # used by HomeKit
    }

    task "server" {

      service {
        name = "homeassistant"

        port = "http"

        check {
          type     = "http"
          path     = "/manifest.json"
          interval = "10s"
          timeout  = "2s"
        }

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.homeassistant.rule=Host(`homeassistant.lab.${var.base_domain}`)",
          "traefik.http.routers.homeassistant.entrypoints=websecure"
        ]
      }

      driver = "docker"

      config {
        image = "homeassistant/home-assistant"
        network_mode = "host"

        ports = ["http","shelly","homekit","mDNS"]
      }

      env {
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 800
        cpu    = 100
      }

      dynamic "template" { # copy file in config folder into /local/integrations
        for_each = fileset(".", "config/*")

        content {
          data            = file(template.value)
          destination     = "/local/${template.value}"
        }
      }


      volume_mount {
        volume      = "homeassistant"
        destination = "/config"
      }
    }

    volume "homeassistant" {
      type            = "csi"
      source          = "homeassistant"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}