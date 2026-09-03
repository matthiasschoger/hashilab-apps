variable "base_domain" {
  default = "missing.environment.variable"
}

job "rallly" {
  datacenters = ["dmz"]
  type        = "service"

  group "server" {

    network {
      mode = "bridge"
      
      port "envoy_metrics" { to = 9101 }
    }

    service {
      name = "rallly-server"

      port = 3000

      check {
        type     = "http"
        path     = "/api/status"
        interval = "5s"
        timeout  = "2s"
        expose   = true
      }

      tags = [ 
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.rallly.rule=Host(`rallly.${var.base_domain}`)",
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9101"
            }

            upstreams {
              destination_name = "rallly-postgres"
              local_bind_port  = 5432
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
        image = "lukevella/rallly:latest"
        force_pull = true
      }

      env {
        TZ = "Europe/Berlin"

        PROXY_MODE = "external"
        DOMAIN     = "rallly.${var.base_domain}"
        NEXT_PUBLIC_BASE_URL = "https://$DOMAIN"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/rallly" }}
# A random secret key used to encrypt sessions (min 32 characters)
# Generate one with: openssl rand -base64 32
SECRET_PASSWORD = {{- .encryption_key }}

DATABASE_URL = postgres://rallly:{{- .db_pass }}@localhost:5432/rallly

SUPPORT_EMAIL = matthias@schoger.net

# Email for the initial admin account
# INITIAL_ADMIN_EMAIL =

# ── SMTP (required for sending emails) ─────────────────────────
SMTP_HOST  = {{- .smtp_host }}
SMTP_PORT  = {{- .smtp_port }}
SMTP_USER  = {{- .smtp_user }}
SMTP_PWD   = {{- .smtp_pass }}
# Leave false for STARTTLS (587, default) or plain (25, 2525).
# Set to true only for implicit TLS (port 465).
SMTP_SECURE = false

# Email address for the initial admin account (optional)
# INITIAL_ADMIN_EMAIL = 

# ── OIDC Single Sign-On (optional) ─────────────────────────────
OIDC_NAME          = Pocket-ID SSO
OIDC_DISCOVERY_URL = {{- .oidc_discovery_url }}
OIDC_CLIENT_ID     = {{- .oidc_client_id }}
OIDC_CLIENT_SECRET = {{- .oidc_client_secret }}
{{- end }}
EOH
      }

      resources {
        memory = 800
        cpu    = 256
      }
    }
  }

  // --- Immich Postgres database and Valkey instance ---

  group "postgres" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9101 }
    }

    service {
      name = "rallly-postgres"

      port = 5432

      check {
        task     = "postgres"
        type     = "script"
        command  = "sh"
        args     = ["-c", "pg_isready -U rallly"]
        interval = "10s"
        timeout  = "2s"
      }

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9101"
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

    task "postgres" {
      driver = "docker"

      shutdown_delay = "3s"   // wait 3s to allow other tasks to shut down

      # backs up the Postgres database and removes all files in the backup folder which are older than 3 days.
      action "backup-postgres" {
        command = "/bin/sh"
        args    = ["-c", <<EOF
pg_dumpall -U "$POSTGRES_USER" | gzip --rsyncable > /var/lib/postgresql/backup/backup.$(date +"%Y%m%d%H%M").sql.gz
echo "cleaning up backup files older than 3 days ..."
find /var/lib/postgresql/backup -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | tail -n +4 | cut -d' ' -f2- | xargs -r rm --
EOF
        ]
      }

      config {
        image = "postgres:18-alpine"
        force_pull = true
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/rallly" }}
POSTGRES_PASSWORD    = {{- .db_pass }}
POSTGRES_USER        = "rallly"
DB_URL               = postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/rallly
{{- end }}
EOH
      }

      volume_mount {
        volume      = "rallly-postgres"
        destination = "/var/lib/postgresql"
      }

      resources {
        cpu    = 50
        memory = 48
      }
    }

    volume "rallly-postgres" {
      type            = "csi"
      source          = "rallly-postgres"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
