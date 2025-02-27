variable "base_domain" {
  default = "missing.environment.variable"
}

job "immich" {
  datacenters = ["dmz"]
  type        = "service"

  group "api-server" {

    network {
      mode = "bridge"

      port "envoy_metrics_api" { to = 9101 }
      port "envoy_metrics_exporter" { to = 9102 }
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
        "dmz.http.routers.immich.entrypoints=cloudflare",
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.immich.rule=Host(`immich.${var.base_domain}`)",
        "traefik.http.routers.immich.tls.certresolver=le",
        "traefik.http.routers.immich.entrypoints=websecure",
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_api}" # make envoy metrics port available in Consul
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9101"
            }

            upstreams { # required for Smart Search
              destination_name = "immich-ml"
              local_bind_port  = 3003
            }
            upstreams {
              destination_name = "immich-postgres"
              local_bind_port  = 5432
            }
            upstreams {
              destination_name = "immich-redis"
              local_bind_port  = 6379
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 200
            memory = 50
          }
        }
      }
    }

    # Unpoller port to get network metrics into Prometheus
    service {
      name = "immich-exporter"

      port = 8000

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_exporter}"
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
            cpu    = 50
            memory = 64
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
        PGID = 100

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
        cpu    = 500
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

    # Immich exporter for Prometheus
    task "immich-exporter" {
      driver = "docker"

      config {
        image = "friendlyfriend/prometheus-immich-exporter:latest"
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/immich.env"
        env             = true
        data            = <<EOH
{{- with nomadVar "nomad/jobs/immich" }}
IMMICH_HOST      = localhost
IMMICH_PORT      = 2283
IMMICH_API_TOKEN = "{{- .immich_api_key }}"
{{- end }}
EOH
      }

      resources {
        cpu    = 50
        memory = 48
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
              destination_name = "immich-redis"
              local_bind_port  = 6379
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 50
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

        devices = [ # map Intel QuickSync to container
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

        IMMICH_TELEMETRY_INCLUDE = "all"
#        IMMICH_TELEMETRY_EXCLUDE = "host"
        
        IMMICH_WORKERS_EXCLUDE = "api"
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
        memory = 2500
        cpu    = 1200
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

  // --- Immich Machine Learning ---

  group "machine-learning" {

    # Run two ML instancen, spread over the two DMZ nodes.
    count = "2"
    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    ephemeral_disk { # Used to cache the machine learning model
      size    = 3000 # MB
      migrate = true
    }

    service {
      name = "immich-ml"

      port = 3003

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
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
            cpu    = 50
            memory = 50
          }
        }
      }
    }

    task "server" {
      driver = "docker"

      user = "1026:100" # matthias:users

      config {
        image = "ghcr.io/immich-app/immich-machine-learning:release"
        force_pull = true

        devices = [ # map Intel QuickSync to container
          {
            host_path = "/dev/dri"
            container_path = "/dev/dri"
          }
        ]
      }

      env {
        TMPDIR       = "/tmp"
        MPLCONFIGDIR = "/local/mplconfig"
        IMMICH_HOST  = "localhost"
        IMMICH_PORT  = "3003"

        TZ           = "Europe/Berlin"

        MACHINE_LEARNING_CACHE_FOLDER = "${NOMAD_ALLOC_DIR}/data/cache"
      }

      resources {
        memory = 2500
        cpu    = 1000
      }
    }
  }

  // --- Immich Postgres database and Redis instance ---

  group "backend" {

    ephemeral_disk {
      # Persistent data for Redis. Nomad will try to preserve the disk between job updates
      size    = 300 # MB
      migrate = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics_postgres" { to = 9101 }
      port "envoy_metrics_redis" { to = 9102 }
    }

    service {
      name = "immich-postgres"

      task = "postgres"
      port = 5432

      check {
        type     = "script"
        command  = "sh"
        args     = ["-c", "psql -U $POSTGRES_USER -d immich  -c 'SELECT 1' || exit 1"]
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
            cpu    = 100
            memory = 50
          }
        }
      }
    }

    # Immich is using Redis to communicate with the worker microservices
    service {
      name = "immich-redis"

      task = "redis"
      port = 6379

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_redis}" # make envoy metrics port available in Consul
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
            cpu    = 200
            memory = 50
          }
        }
      }
    }

    task "postgres" {
      driver = "docker"

      # proper user id is required 
      user = "1026:100" # matthias:users

      # backs up the Postgres database and removes all files in the backup folder which are older than 3 days.
      action "backup-postgres" {
        command = "/bin/sh"
        args    = ["-c", <<EOF
pg_dumpall -U "$POSTGRES_USER" | gzip --rsyncable > /var/lib/postgresql/data/backup/backup.$(date +"%Y%m%d%H%M").sql.gz
echo "cleaning up backup files older than 3 days ..."
find /var/lib/postgresql/data/backup/* -mtime +3 -exec rm {} \;
EOF
        ]
      }

      config {
         image = "tensorchord/pgvecto-rs:pg14-v0.2.1"
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/variables.env"
        env         = true
        perms       = 400
        data        = <<EOH
{{- with nomadVar "nomad/jobs/immich" }}
POSTGRES_PASSWORD = {{- .db_pass }}
POSTGRES_USER     = {{- .db_user }}
DB_URL            = postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/immich
{{- end }}
EOH
      }

      volume_mount {
        volume      = "immich-postgres"
        destination = "/var/lib/postgresql/data"
      }

      resources {
        cpu    = 1000
        memory = 1000
      }
    }
 
     # Redis cache, used as an event queue to schedule jobs
    task "redis" {
      driver = "docker"

      config {
        image = "redis:6.2-alpine"

        args = [ "/local/redis.conf" ]
      }

      template {
        destination = "local/redis.conf"
        data        = <<EOH
save 10 1 # save every 10 seconds if at least one key has changed

dir {{ env "NOMAD_ALLOC_DIR" }}/data
EOH
      }

      resources {
        memory = 300
        cpu    = 150
      }
    }

    volume "immich-postgres" {
      type            = "csi"
      source          = "immich-postgres"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
