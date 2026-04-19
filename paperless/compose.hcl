variable "base_domain" {
  default = "missing.environment.variable"
}

job "paperless" {
  datacenters = ["home"]
  type        = "service"
/*
  group "api-server" {

    network {
      mode = "bridge"
      
      port "envoy_metrics" { to = 9101 }
    }

    service {
      name = "immich-api"

      task = "server"
      port = 2283

      check {
        type     = "http"
        path     = "/api/server/ping"
        interval = "5s"
        timeout  = "2s"
        expose   = true
      }

      tags = [ # dual-head to be able to upload large assets (videos) when in the internal network
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.immich.rule=Host(`immich.${var.base_domain}`)",
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.immich.rule=Host(`immich.${var.base_domain}`)"
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
              destination_name = "immich-ml" # required for Smart Search
              local_bind_port  = 3003
            }
            upstreams {
              destination_name = "immich-postgres"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "immich-valkey"
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
        image = "ghcr.io/immich-app/immich-server:release"
        force_pull = true
      }

      env {
        NODE_ENV              = "production"
        REDIS_HOSTNAME        = "127.0.0.1"
        IMMICH_MEDIA_LOCATION = "/data"

        TZ = "Europe/Berlin"

        # user and group ID
        PUID = 1026
        PGID = 1000

        IMMICH_TELEMETRY_INCLUDE = "all"
#        IMMICH_TELEMETRY_EXCLUDE = "host"

        IMMICH_WORKERS_INCLUDE = "api"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/immich" }}
DB_URL=postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/immich
{{- end }}
EOH
      }

      resources {
        memory = 800
        cpu    = 512
      }

      volume_mount {
        volume      = "immich-data"
        destination = "/data"
      }
      volume_mount {
        volume      = "immich-homes"
        destination = "/homes"
      }
    }

    volume "immich-data" {
      type            = "csi"
      source          = "immich-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "immich-homes" { # external library location
      type            = "csi"
      source          = "immich-homes"
      access_mode     = "multi-node-reader-only"
      attachment_mode = "file-system"
      read_only       = true
    }
  }

  // --- Immich Worker ---

  group "worker" {

    # Run two worker instancen, spread over the two DMZ nodes.
    count = "2"
    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "immich-worker"

      port = 2283

      check {
        type     = "http"
        path     = "/api/server/ping"
        interval = "5s"
        timeout  = "2s"
        expose   = true
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

            upstreams {
              destination_name = "immich-ml"
              local_bind_port  = 3003
            }
            upstreams {
              destination_name = "immich-postgres"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "immich-valkey"
              local_bind_port  = 6379
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 128
            memory = 50
          }
        }
      }
    }

    # task worker, doing all the processing async
    task "server" {
      driver = "docker"

      config {
        image = "ghcr.io/immich-app/immich-server:release"
        force_pull = true

        devices = [ # map Intel QuickSync to container, allowing for hardware encoding
          {
            host_path = "/dev/dri"
            container_path = "/dev/dri"
          }
        ]
      }

      env {
        NODE_ENV              = "production"
        REDIS_HOSTNAME        = "127.0.0.1"
        IMMICH_MEDIA_LOCATION = "/data"

        # user and group ID
        PUID = 1026
        PGID = 100

        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/immich" }}
DB_URL=postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/immich
{{- end }}
EOH
      }

      resources {
        memory = 3500
        cpu    = 4000
      }

      volume_mount {
        volume      = "immich-data"
        destination = "/data"
      }
      volume_mount {
        volume      = "immich-homes"
        destination = "/homes"
      }
    }

    volume "immich-data" {
      type            = "csi"
      source          = "immich-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    volume "immich-homes" { # external library location
      type            = "csi"
      source          = "immich-homes"
      access_mode     = "multi-node-reader-only"
      attachment_mode = "file-system"
      read_only       = true
    }
  }

*/
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

      # user = "1026:1000" 

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
        image = "postgres:16"
        force_pull = true
      }

      env {
        TZ = "Europe/Berlin"

        # user and group ID
        # PUID = 1026
        # PGID = 1000
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/paperless" }}
POSTGRES_PASSWORD    = {{- .db_pass }}
POSTGRES_USER        = {{- .db_user }}
DB_URL               = postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/paperless
{{- end }}
EOH
      }

      volume_mount {
        volume      = "paperless-postgres"
        destination = "/var/lib/postgresql/data"
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
        image = "valkey/valkey:9"
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
