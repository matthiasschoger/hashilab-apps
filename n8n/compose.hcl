variable "base_domain" {
  default = "missing.environment.variable"
}

job "n8n" {
  datacenters = ["home"]
  type        = "service"

  group "n8n" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "n8n"

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
        "traefik.http.routers.n8n.rule=Host(`n8n.lab.${var.base_domain}`)",
        "traefik.http.routers.n8n.entrypoints=websecure"
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

      user = "1000:1000" # matthias:users

      config {
        image = "n8nio/n8n:latest"
        # image = "busybox:latest"

        # command = "sleep"

        # args = [
        #   "infinity",
        # ]

        mount {
          type     = "bind"
          target   = "/home/node/.n8n"
          source   = "n8n"
          readonly = false
        }
      }

      env {
        TZ = "Europe/Berlin"

        # Database Configuration
        DB_TYPE                 = "sqlite"
        DB_SQLITE_DATABASE_FILE = "/home/node/.n8n/database.sqlite"
        DB_SQLITE_VACUUM_ON_STARTUP = true

        # Basic Configuration
        N8N_PROTOCOL = "https"
        N8N_HOST     = "n8n.lab.${var.base_domain}"
        N8N_PORT     = "443"
        WEBHOOK_URL  = "https://n8n.lab.${var.base_domain}/"

        # User Management & Security
        N8N_USER_MANAGEMENT_DISABLED      = "false"
        N8N_EMAIL_MODE                    = "smtp"

        # Performance Settings
        N8N_CONCURRENCY_PRODUCTION_LIMIT  = "5"
        EXECUTIONS_DATA_MAX_AGE           = "336" # 14 days in hours
        EXECUTIONS_DATA_PRUNE             = "true"

        # Binary Data Storage
        BINARY_DATA_MODE                  = "filesystem"
        N8N_BINARY_DATA_STORAGE_PATH      = "/home/node/.n8n/binaryData/"

        # Metrics
        METRICS                           = true

        # Development Settings
        N8N_LOG_LEVEL                     = "info"
        N8N_VERSION_NOTIFICATIONS_ENABLED = "true"

        # Disable diagnostics for privacy
        N8N_DIAGNOSTICS_ENABLED           = "false"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/n8n" }}
N8N_ENCRYPTION_KEY  = {{ .encryption_key }}

N8N_SMTP_HOST       = {{ .smtp_host }}
N8N_SMTP_PORT       = {{ .smtp_port }}
N8N_SMTP_USER       = {{ .smtp_user }}
N8N_SMTP_PASS       = {{ .smtp_pass }}
N8N_SMTP_SENDER     = {{ .smtp_sender }}
{{- end }}
EOH
      }

      resources {
        memory = 200
        cpu    = 100
      }

      volume_mount {
        volume      = "n8n"
        destination = "/home/node/.n8n"
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