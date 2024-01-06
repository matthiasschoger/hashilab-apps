job "nginx" {
  datacenters = ["home"]
  type        = "service"

  group "nginx" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    restart {
      attempts = 3
      delay = "1m"
      mode = "fail"
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "nginx"

      port = 80

      check {
        type     = "http"
        path     = "/alive"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.nginx.rule=Host(`schoger.net`) || Host(`www.schoger.net`)",
        "traefik.http.routers.nginx.entrypoints=inet-websecure"
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              protocol = "http"
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
        image = "nginx:latest"

        volumes = [ "local:/etc/nginx/conf.d" ]      
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        data        = file("default.conf")
        destination = "local/default.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"
      }

      resources {
        memory = 50
        cpu    = 50
      }

      volume_mount {
        volume      = "nginx"
        destination = "/usr/share/nginx/content"
      }
    }

    volume "nginx" {
      type            = "csi"
      source          = "nginx"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

  }
}