variable "base_domain" {
  default = "missing.environment.variable"
}

job "grafana" {
  datacenters = ["home"]
  type = "service"

  group "grafana" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "grafana"
      
      port = 3000

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.grafana.rule=Host(`grafana.lab.${var.base_domain}`)"
      ]

      check {
        type     = "http"
        path     = "/api/health"
        interval = "5s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9102"
            }
            # link Loki + Prometheus for all the SDN goodness
            upstreams {
              destination_name = "prometheus"
              local_bind_port  = 9090
            }
            upstreams {
              destination_name = "loki"
              local_bind_port  = 3100
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 96
          }
        }
      }
    }

    task "server" {

      driver = "docker"

      config { 
#        image = "grafana/grafana:latest"
        image = "grafana/grafana:12.4.3"
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

GF_LOG_LEVEL = "WARN"
GF_LOG_MODE = "console"
GF_PATHS_PROVISIONING = "/etc/grafana/provisioning"

GF_SMTP_ENABLED=true
{{- with nomadVar "nomad/jobs/grafana" }}
GF_SMTP_HOST={{ .smtp_host }}:{{ .smtp_port }}
GF_SMTP_USER={{ .smtp_user }}
GF_SMTP_PASSWORD={{ .smtp_pass }}
GF_SMTP_FROM_ADDRESS={{ .smtp_sender }}
{{- end }}
EOH
      }

      resources {
        cpu    = 400
        memory = 384
      }

      volume_mount {
        volume      = "grafana"
        destination = "/var/lib/grafana"
      }    
    }

    volume "grafana" {
      type            = "csi"
      source          = "grafana"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
