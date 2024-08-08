job "immich" {
  datacenters = ["home"]
  type        = "service"

  group "api" {

    constraint {
      attribute = "${node.class}"
      value     = "dmz"
    }

    network {
      mode = "bridge"

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

      tags = [ # dual-head to make imports easier
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.immich.rule=Host(`immich.schoger.net`)",
        "dmz.http.routers.immich.entrypoints=cloudflare",
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.immich.rule=Host(`immich.lab.home`)",
        "traefik.http.routers.immich.entrypoints=websecure",
      ]

      meta {
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_api}" # make envoy metrics port available in Consul
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
            cpu    = 50
            memory = 48
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
        memory = 512
        cpu    = 500
      }

      volume_mount {
        volume      = "immich-homes"
        destination = "/homes"
      }

      volume_mount {
        volume      = "immich-data"
        destination = "/data"
      }
    }

    # Redis cache
    task "redis" {
       driver = "docker"

      config {
        image = "redis:alpine"
      }

      resources {
        memory = 65
        cpu    = 100
      }
    }

    volume "immich-data" {
      type            = "csi"
      source          = "immich-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }

    volume "immich-homes" {
      type            = "csi"
      source          = "immich-homes"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }

  // --- Immich Worker ---

  group "worker" {

    # Run two worker instancen, spread over the two DMZ nodes.
    count = "2"
    constraint {
      attribute = "${node.class}"
      value     = "dmz"
    }
    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "immich-worker"

      port = 3002

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
            memory = 48
          }
        }
      }
    }

    # microservices is the task worker, doing all the processing async
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
        memory = 2048
        cpu    = 1000
      }

      volume_mount {
        volume      = "immich-data"
        destination = "/data"
      }
    }

    volume "immich-data" {
      type            = "csi"
      source          = "immich-data"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
  }

  // --- Immich Machine Learning ---

  group "machine-learning" {

    # Run two ML instancen, spread over the two DMZ nodes.
    count = "2"
    constraint {
      attribute = "${node.class}"
      value     = "dmz"
    }
    constraint {
      distinct_hosts = true
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    ephemeral_disk {
      # Used to cache the machine learning model
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
            memory = 48
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
        TMPDIR       = "/local"
        MPLCONFIGDIR = "/local"
        IMMICH_HOST  = "localhost"
        IMMICH_PORT  = "3003"

        MACHINE_LEARNING_CACHE_FOLDER = "${NOMAD_ALLOC_DIR}/data/cache"

        TZ           = "Europe/Berlin"
      }

      resources {
        memory = 1536
        cpu    = 1000
      }
    }
  }

  // --- Immich Postgres database ---

  group "postgres" {

    constraint {
      attribute = "${node.class}"
      value     = "dmz"
    }

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
            memory = 48
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
        memory = 384
        cpu    = 200
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
