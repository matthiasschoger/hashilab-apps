variable "base_domain" {
  default = "missing.environment.variable"
}

job "home-assistant" {
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

    service {
      name = "home-assistant"

      port = "http"

      check {
        type     = "http"
        path     = "/manifest.json"
        interval = "10s"
        timeout  = "2s"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.homeassistant.rule=Host(`homeassistant.lab.${var.base_domain}`)"
      ]
    }

    task "server" {

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

      template {
        destination = "local/config/homekit.yaml"
        data        = <<EOH
  - name: Home Assistant Bridge
    port: {{ env "NOMAD_HOST_PORT_homekit" }}
    advertise_ip: "{{ env "NOMAD_IP_homekit" }}"
    filter:
      include_domains:
        - button
        - climate
        - light
        - switch
        - sensor
EOH
      }

      template {
        destination = "local/config/http.yaml"
        data        = <<EOH
  use_x_forwarded_for: true
  trusted_proxies:
#  - 0.0.0.0/0      # everything is trusted
  - 192.168.0.0/16 # host network
  - 127.0.0.1/32   # Consul Connect
  - 172.16.0.0/12  # Bridge network
#  ip_ban_enabled: true
#  login_attempts_threshold: 5
EOH
      }

      template {
        destination = "local/config/logger.yaml"
        data        = <<EOH
  default: info
#  logs:
#    homeassistant.components.http: debug
#    homeassistant.components.homekit: debug
#    pyhap: debug
EOH
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