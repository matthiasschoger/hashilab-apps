job "immich" {
  datacenters = ["dmz"]
  type        = "service"

  group "api" {

    network {
      mode = "bridge"

      port "immich_metrics" { to = 8081 }

      port "envoy_metrics_api" { to = 9102 }
      port "envoy_metrics_redis" { to = 9103 }
    }

    service {
      name = "immich-api"

      task = "server"
      port = 3001

      check {
        type     = "http"
        path     = "/api/server-info/ping"
        interval = "10s"
        timeout  = "2s"
        expose   = true
      }

      tags = [                    # dual-head to be able to upload large assets (videos) when in the internal network
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.immich.rule=Host(`immich.schoger.net`)",
        "dmz.http.routers.immich.entrypoints=cloudflare",
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.immich.rule=Host(`immich.schoger.net`)",
        "traefik.http.routers.immich.entrypoints=websecure",
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_api}" # make envoy metrics port available in Consul
        metrics_port = "${NOMAD_HOST_PORT_immich_metrics}"
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9102"
            }

            upstreams { # required for Smart Search
              destination_name = "immich-ml"
              local_bind_port  = 3003
            }
            upstreams {
              destination_name = "immich-postgres"
              local_bind_port  = 5432
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
              envoy_prometheus_bind_addr = "0.0.0.0:9103"
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

    # The main immich API server
    task "server" {
      driver = "docker"

      user = "1026:100" # matthias:users
    
      config {
        image = "ghcr.io/immich-app/immich-server:release"
        force_pull = true
      }

      env {
        NODE_ENV              = "production"
        REDIS_HOSTNAME        = "127.0.0.1"
        IMMICH_MEDIA_LOCATION = "/data"

        TZ = "Europe/Berlin"

        IMMICH_API_METRICS = true
        IMMICH_HOST_METRICS = true
        IMMICH_IO_METRICS = true
        IMMICH_JOB_METRICS = true

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

    # Redis cache
    task "redis" {
       driver = "docker"

      config {
        image = "redis:alpine"
        force_pull = true
      }

      resources {
        memory = 300
        cpu    = 150
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

      port "immich_metrics" { to = 8082 }

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "immich-worker"

      port = 3002

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}" # make envoy metrics port available in Consul
        metrics_port = "${NOMAD_HOST_PORT_immich_metrics}"
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

      user = "1026:100" # matthias:users

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

        TZ = "Europe/Berlin"

        IMMICH_API_METRICS = true
        IMMICH_HOST_METRICS = true
        IMMICH_IO_METRICS = true
        IMMICH_JOB_METRICS = true
        
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
      size    = 1500 # MB
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

  // --- Immich Postgres database ---

  group "postgres" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "immich-postgres"

      port = 5432

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
            cpu    = 100
            memory = 50
          }
        }
      }
    }

    task "server" {
      driver = "docker"

      # proper user id is required 
      user = "1026:100" # matthias:users

      # backs up the Postgres database and removes all files in the backup folder which are older than 3 days.
      action "backup-postgres" {
        command = "/bin/sh"
        args    = ["-c", <<EOF
pg_dumpall -U "$POSTGRES_USER" | gzip > /var/lib/postgresql/data/backup/backup.$(date +"%Y%m%d%H%M").sql.gz
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
POSTGRES_PASSWORD={{- .db_pass }}
POSTGRES_USER={{- .db_user }}
DB_URL=postgres://{{- .db_user }}:{{- .db_pass }}@127.0.0.1:5432/immich
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
 
    volume "immich-postgres" {
      type            = "csi"
      source          = "immich-postgres"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
