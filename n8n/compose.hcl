variable "base_domain" {
  default = "missing.environment.variable"
}

job "n8n" {
  datacenters = ["home"]
  type        = "service"

  group "api-server" {

    network {
      mode = "bridge"

      port "n8n_exporter_metrics" { to = 5678 }

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "n8n-api"

      port = 5678

      check {
        type     = "http"
        path     = "/healthz"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.n8n.rule=Host(`n8n.lab.${var.base_domain}`)"
      ]

      meta {
        metrics_port = "${NOMAD_HOST_PORT_n8n_exporter_metrics}" # make n8n metrics port available in Consul 
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"  # make envoy metrics port available in Consul
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

      user = "1000:1000" 

      config {
        image = "n8nio/n8n:latest"
      }

      env {
        TZ = "Europe/Berlin"

        # user and group ID
        PUID = 1000
        PGID = 1000

        N8N_DATA = "/home/node/.n8n"

        # Database Configuration
        DB_TYPE                     = "sqlite"
        DB_SQLITE_VACUUM_ON_STARTUP = true

        # Binary Data Storage
        BINARY_DATA_MODE            = "filesystem"

        # Basic Configuration
        N8N_PROTOCOL = "http"
        N8N_PORT     = "5678"

        N8N_EDITOR_BASE_URL = "https://n8n.lab.${var.base_domain}"
        WEBHOOK_URL         = "https://n8n.lab.${var.base_domain}/"
        N8N_PROXY_HOPS      = 1

        # Prometheus Metrics
        N8N_METRICS                       = true
        QUEUE_HEALTH_CHECK_ACTIVE         = true

        # Development Settings
        N8N_LOG_LEVEL                     = "info"
        N8N_VERSION_NOTIFICATIONS_ENABLED = "true"

        # Diagnostics
        N8N_DIAGNOSTICS_ENABLED           = "true"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/n8n" }}
N8N_ENCRYPTION_KEY  = {{ .N8N_ENCRYPTION_KEY }}

N8N_SMTP_HOST       = {{ .N8N_SMTP_HOST }}
N8N_SMTP_PORT       = {{ .N8N_SMTP_PORT }}
N8N_SMTP_USER       = {{ .N8N_SMTP_USER }}
N8N_SMTP_PASS       = {{ .N8N_SMTP_PASS }}
N8N_SMTP_SENDER     = {{ .N8N_SMTP_SENDER }}
{{- end }}
EOH
      }

      resources {
        memory = 512
        cpu    = 400
      }

      volume_mount {
        volume      = "n8n"
        destination = "/home/node"
      }
    }

    volume "n8n" {
      type            = "csi"
      source          = "n8n"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}