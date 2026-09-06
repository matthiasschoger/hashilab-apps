variable "base_domain" {
  default = "missing.environment.variable"
}

job "paperless" {
  datacenters = ["home"]
  type        = "service"

  group "api-server" {

    network {
      mode = "bridge"
      
      port "envoy_metrics" { to = 9101 }
    }

    service {
      name = "paperless-ui"

      port = 8000

      # check {
      #   type     = "http"
      #   path     = "/api/status/"
      #   interval = "5s"
      #   timeout  = "2s"
      #   expose   = true
      # }

      tags = [ # dual-head to be able to upload large assets (videos) when in the internal network
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.paperless.rule=Host(`paperless.lab.${var.base_domain}`)"
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
              destination_name = "paperless-postgres"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "paperless-valkey"
              local_bind_port  = 6379
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 48
            memory = 50
          }
        }
      }
    }

    # The main immich API server
    task "server" {
      driver = "docker"

      config {
        image = "ghcr.io/paperless-ngx/paperless-ngx:latest"
      }

      env {
        TZ = "Europe/Berlin"

        PAPERLESS_TIME_ZONE = "Europe/Berlin"
        PAPERLESS_OCR_LANGUAGE = "deu+eng"

        # user and group ID
        USERMAP_UID = 1026
        USERMAP_GID = 100

        PAPERLESS_URL = "https://paperless.lab.${var.base_domain}"

        PAPERLESS_REDIS = "redis://localhost:6379"
        PAPERLESS_DBHOST = "localhost"
        PAPERLESS_DBENGINE = "postgresql"
        PAPERLESS_DBUSER = "postgres"


        PAPERLESS_ARCHIVE_MODE = "move"
        PAPERLESS_CONSUMER_RECURSIVE = true
        PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = true
        PAPERLESS_CONSUMER_DELETE_DUPLICATES = true

        PAPERLESS_DATA_DIR        = "/paperless/data"
        PAPERLESS_MEDIA_ROOT      = "/paperless/media"
        PAPERLESS_CONSUMPTION_DIR = "/paperless/consume"
        PAPERLESS_EXPORT_DIR      = "/paperless/export"
        PAPERLESS_MODEL_FILE      = "/paperless/models"

        # PAPERLESS_TIKA_ENABLED: 1
        # PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://localhost:3000
        # PAPERLESS_TIKA_ENDPOINT: http://localhost:9998
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/paperless" }}
PAPERLESS_SECRET_KEY = "{{- .secret_key }}"

PAPERLESS_DBPASS = {{- .db_pass }}
{{- end }}
EOH
      }

      resources {
        memory = 800
        cpu    = 512
      }

      volume_mount {
        volume      = "paperless-data"
        destination = "/paperless"
      }
    }

    volume "paperless-data" {
      type            = "csi"
      source          = "paperless-data"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
 
  // --- Paperless Postgres database and Valkey instance ---

  group "backend" {

    ephemeral_disk {
      # Persistent data for Valkey. Nomad will try to preserve the disk between job updates
      size    = 300 # MB
      migrate = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics_postgres" { to = 9101 }
      port "envoy_metrics_valkey" { to = 9102 }
    }

    service {
      name = "paperless-postgres"

      task = "postgres"
      port = 5432

      check {
        type     = "script"
        command  = "sh"
        args     = ["-c", "psql -U $POSTGRES_USER -d paperless  -c 'SELECT 1' || exit 1"]
        interval = "10s"
        timeout  = "2s"
      }

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_postgres}" # make envoy metrics port available in Consul
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
            cpu    = 256
            memory = 50
          }
        }
      }
    }

    # Paperless is using Valkey to communicate with the worker microservices
    service {
      name = "paperless-valkey"

      task = "valkey"
      port = 6379

      check {
        type     = "script"
        command  = "sh"
        args     = ["-c", "redis-cli ping || exit 1"]
        interval = "10s"
        timeout  = "2s"
      }

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_valkey}" # make envoy metrics port available in Consul
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
            cpu    = 256
            memory = 50
          }
        }
      }
    }

    task "postgres" {
      driver = "docker"

      # backs up the Postgres database and removes all files in the backup folder which are older than 3 days.
      action "backup-postgres" {
        command = "/bin/sh"
        args    = ["-c", <<EOF
pg_dumpall -U "$POSTGRES_USER" | gzip --rsyncable > /var/lib/postgresql/data/backup/backup.$(date +"%Y%m%d%H%M").sql.gz
echo "cleaning up backup files older than 3 days ..."
find /var/lib/postgresql/data/backup -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | tail -n +4 | cut -d' ' -f2- | xargs -r rm --
EOF
        ]
      }

      config {
        image = "postgres:18"
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
{{- with nomadVar "nomad/jobs/paperless" }}
POSTGRES_DB       = paperless
POSTGRES_USER     = "postgres"
POSTGRES_PASSWORD = {{- .db_pass }}
{{- end }}
EOH
      }

      volume_mount {
        volume      = "paperless-postgres"
        destination = "/var/lib/postgresql"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
 
     # Valkey cache, used as an event queue to schedule jobs
    task "valkey" {
      driver = "docker"

      config {
        image = "valkey/valkey:9-alpine"
        force_pull = true

        args = [ "/local/valkey.conf" ]
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "local/valkey.conf"
        data        = <<EOH
# save every 60 seconds if at least 100 keys have changed
save 60 100

maxmemory {{ env "NOMAD_MEMORY_LIMIT" | parseInt | subtract 5 }}mb
dir {{ env "NOMAD_ALLOC_DIR" }}/data
EOH
      }

      resources {
        memory = 200
        cpu    = 300
      }
    }

    volume "paperless-postgres" {
      type            = "csi"
      source          = "paperless-postgres"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
