variable "base_domain" {
  default = "missing.environment.variable"
}

job "bookstack" {
  datacenters = ["home"]
  type        = "service"

  group "bookstack" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "bookstack-server"

      port = 80

      check {
        type     = "http"
        path     = "/status"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.bookstack.rule=Host(`bookstack.lab.${var.base_domain}`)",
        "traefik.http.routers.bookstack.entrypoints=websecure"
      ]

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
              destination_name = "bookstack-mariadb"
              local_bind_port  = 3306
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

      config {
        image = "linuxserver/bookstack:latest"
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

{{- with nomadVar "nomad/jobs/bookstack" }}
DB_HOST = "127.0.0.1:3306" 
DB_USER = "bookstack"
DB_PASS = "{{- .db_pass }}"
DB_DATABASE = "bookstackapp"
APP_URL = "https://bookstack.lab.${var.base_domain}"
{{- end }}
EOH
      }

      resources {
        memory = 200
        cpu    = 100
      }

      volume_mount {
        volume      = "bookstack-app"
        destination = "/config"
      }
    }

    volume "bookstack-app" {
      type            = "csi"
      source          = "bookstack-app"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }


  group "mariadb" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "bookstack-mariadb"

      port = 3306

      check {
        type     = "script"
        command  = "sh"
        args     = ["-c", "/usr/bin/mariadb --user=$MYSQL_USER --password=$MYSQL_PASSWORD --execute \"SHOW DATABASES;\""]
        interval = "10s"
        timeout  = "2s"
        task     = "server"
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

      config {
        image = "lscr.io/linuxserver/mariadb:11.4.5"
      }

      # backs up the MariaDB database and removes all files in the backup folder which are older than 3 days
      action "backup-mariadb" {
        command = "/bin/sh"
        args    = ["-c", <<EOH
mariadb-dump -u bookstack --password=$MYSQL_PASSWORD --all-databases | gzip > /config/backup/backup.$(date +"%Y%m%d%H%M").gz
echo "cleaning up backup files older than 3 days ..."
find /config/backup -maxdepth 1 -type f -printf '%T@ %p\n' | sort -nr | tail -n +4 | cut -d' ' -f2- | xargs -r rm --
EOH
        ]
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

{{- with nomadVar "nomad/jobs/bookstack" }}
MYSQL_ROOT_PASSWORD = "{{- .db_pass }}"
MYSQL_DATABASE = "bookstackapp"
MYSQL_USER = "bookstack"
MYSQL_PASSWORD = "{{- .db_pass }}"
{{- end }}
EOH
      }

      resources {
        memory = 512
        cpu    = 100
      }

      volume_mount {
        volume      = "bookstack-db"
        destination = "/config"
      }
    }

    volume "bookstack-db" {
      type            = "csi"
      source          = "bookstack-db"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}