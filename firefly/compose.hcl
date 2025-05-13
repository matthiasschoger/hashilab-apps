variable "base_domain" {
  default = "missing.environment.variable"
}

job "firefly" {
  datacenters = ["home"]
  type        = "service"

  group "firefly" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "firefly-server"

      port = 8080

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
        "traefik.http.routers.firefly.rule=Host(`firefly.lab.${var.base_domain}`)",
        "traefik.http.routers.firefly.entrypoints=websecure"
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
              destination_name = "firefly-mariadb"
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
        image = "fireflyiii/core:latest"
      }

      # template {
      #   destination = "secrets/firefly.stack.env"
      #   env         = true
      #   data        = file("firefly.stack.env")
      # }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

# see https://raw.githubusercontent.com/firefly-iii/firefly-iii/main/.env.example
{{- with nomadVar "nomad/jobs/firefly" }}
SITE_OWNER="{{ .email_receipient }}"
APP_KEY=39wLmTtBi92jNiDPAH95sVrVvQMn7tKs

DEFAULT_LANGUAGE=en_US
DEFAULT_LOCALE=de_DE
TZ=Europe/Berlin

TRUSTED_PROXIES=192.168.0.3

DB_CONNECTION=mysql
DB_HOST=localhost
DB_PORT=3306
DB_DATABASE=firefly
DB_USERNAME=firefly
DB_PASSWORD = "{{- .db_pass }}"

# If you want Firefly III to email you, update these settings
# For instructions, see: https://docs.firefly-iii.org/how-to/firefly-iii/advanced/notifications/#email
# If you use Docker or similar, you can set these variables from a file by appending them with _FILE
MAIL_MAILER=log
MAIL_HOST=smtp.lab.${var.base_domain}
MAIL_PORT=1025
MAIL_FROM="{{ .email_user }}"
MAIL_USERNAME="{{ .email_user }}"
MAIL_PASSWORD="{{ .email_pass }}"

# Set this value to true if you want to set the location of certain things, like transactions.
# Since this involves an external service, it's optional and disabled by default.
ENABLE_EXTERNAL_MAP=true

# The map will default to this location:
MAP_DEFAULT_LAT=51.983333
MAP_DEFAULT_LONG=5.916667
MAP_DEFAULT_ZOOM=6

# For more info: https://docs.firefly-iii.org/how-to/firefly-iii/advanced/cron/
STATIC_CRON_TOKEN="{{ .cron_token }}"

APP_URL="https://firefly.lab.${var.base_domain}"
{{- end }}

EOH
      }

      resources {
        memory = 200
        cpu    = 100
      }

      volume_mount {
        volume      = "firefly-app"
        destination = "/var/www/html/storage/upload"
      }
    }

    volume "firefly-app" {
      type            = "csi"
      source          = "firefly-app"
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
      name = "firefly-mariadb"

      port = 3306

      # check {
      #   type     = "script"
      #   command  = "sh"
      #   args     = ["-c", "/usr/bin/mariadb --user=$MYSQL_USER --password=$MYSQL_PASSWORD --execute \"SHOW DATABASES;\""]
      #   interval = "10s"
      #   timeout  = "2s"
      #   task     = "server"
      # }

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

      user = "1026:100" # matthias:users

      config {
        image = "mariadb:11.4.5"
      }

      # backs up the MariaDB database and removes all files in the backup folder which are older than 3 days
      action "backup-mariadb" {
        command = "/bin/sh"
        args    = ["-c", <<EOH
mariadb-dump -u firefly --password=$MYSQL_PASSWORD --all-databases | gzip > /var/lib/mysql/backup/backup.$(date +"%Y%m%d%H%M").gz
echo "cleaning up backup files older than 3 days ..."
find /config/backup/* -mtime +3 -exec rm {} \;
EOH
        ]
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

{{- with nomadVar "nomad/jobs/firefly" }}
MYSQL_ROOT_PASSWORD = "{{- .db_pass }}"
MYSQL_USER = "firefly"
MYSQL_PASSWORD = "{{- .db_pass }}"
{{- end }}
EOH
      }

      resources {
        memory = 384
        cpu    = 100
      }

      volume_mount {
        volume      = "firefly-db"
        destination = "/var/lib/mysql"
      }
    }

    volume "firefly-db" {
      type            = "csi"
      source          = "firefly-db"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}