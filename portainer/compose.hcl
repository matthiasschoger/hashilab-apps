job "portainer" {
  datacenters = ["home"]
  type        = "service"

  group "portainer" {

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

      port "agent" { static = 8000 }
    }

    service {
      name = "portainer"

      port = 9000

      check {
        type     = "http"
        path     = "/api/system/status"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.portainer.rule=Host(`portainer.lab.home`)",
        "traefik.http.routers.portainer.entrypoints=websecure"
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
            cpu    = 100
            memory = 64
          }
        }
      }
    }

    task "server" {
      driver = "docker"

      config {
#        image = "portainer/portainer-ee:latest"
        image = "portainer/portainer-ee:2.18.4"

#        args = ["--log-level=DEBUG"]

        volumes = [
          "/etc/ssl/certs:/etc/ssl/certs:ro"    # use TLS certs from host OS, including the Schoger Home cert
        ]      

        ports = ["http","agent"]
      }

      resources {
        memory = 50
        cpu    = 50
      }

      volume_mount {
        volume      = "portainer"
        destination = "/data"
      }
    }

    volume "portainer" {
      type            = "csi"
      source          = "portainer"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}