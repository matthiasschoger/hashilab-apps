job "gitea" {
  datacenters = ["home"]
  type        = "service"

  group "gitea" {

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
      name = "gitea"

      check {
        type     = "http"
        path     = "/api/healthz"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      port = 3000

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.gitea.rule=Host(`gitea.lab.home`)",
        "traefik.http.routers.gitea.entrypoints=websecure"
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
            memory = 64
          }
        }
      }
    }

    task "server" {
      driver = "docker"

      config {
        image = "gitea/gitea:latest"

        volumes = [
          "/etc/ssl/certs:/etc/ssl/certs:ro"    # use TLS certs from host OS, including the Schoger Home cert
        ]      
      }

      env {
        GITEA__webhook__ALLOWED_HOST_LIST = "private"
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 600
        cpu    = 100
      }

      template {
        destination = "local/config.ini"
        data            = <<EOH
[webhook]
ALLOWED_HOST_LIST = private
SKIP_TLS_VERIFY = false
EOH
      }

      volume_mount {
        volume      = "gitea"
        destination = "/data"
      }
    }

    volume "gitea" {
      type            = "csi"
      source          = "gitea"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
