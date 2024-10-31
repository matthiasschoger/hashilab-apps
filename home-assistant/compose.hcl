job "homeassistant" {
  datacenters = ["home"]
  type        = "service"

  group "homeassistant" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      mode = "bridge"

      port "shelly" { to = 5683 }    # UDP, reservation for Shelly port
      port "mDNS" { to = 5353 }      # UDP, used by HomeKit

      port "envoy_metrics_ui" { to = 9102 }
      port "envoy_metrics_homekit" { to = 9103 }
    }

    service {
      name = "homeassistant-http"

      port = 8123

      check {
        type     = "http"
        path     = "/manifest.json"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.homeassistant.rule=Host(`homeassistant.lab.schoger.net`)",
        "traefik.http.routers.homeassistant.entrypoints=websecure"
      ]

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port_ui = "${NOMAD_HOST_PORT_envoy_metrics_ui}"
        envoy_metrics_port_homekit = "${NOMAD_HOST_PORT_envoy_metrics_homekit}"
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

    # homekit port, configured in homekit.yaml and proxied by the Consul ingress gateway
    service {
      name = "homeassistant-homekit"

      port = 21063

      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9103"
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

    # shelly port (UDP), proxied by NGINX in consul-ingres
    service {
      name = "homeassistant-shelly"

      port = "shelly"
    }

    # mDNS port (UDP) for homekit, proxied by NGINX in consul-ingres
    service {
      name = "homeassistant-mDNS-listener"

      port = "mDNS"
    }


    task "server" {

      driver = "docker"

      config {
        image = "homeassistant/home-assistant"
#        network_mode = "host"

#        ports = ["http","shelly","homekit","mDNS"]
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