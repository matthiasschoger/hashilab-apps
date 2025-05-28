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
        path     = "/health"
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

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/stack.env"
        env         = true
        data        = file("stack.env")
      }

      resources {
        memory = 200
        cpu    = 500
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

  group "importer" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "firefly-importer"

      port = 8080

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.firefly-importer.rule=Host(`firefly-importer.lab.${var.base_domain}`)",
        "traefik.http.routers.firefly-importer.entrypoints=websecure"
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
              destination_name = "firefly-server"
              local_bind_port  = 80
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

    task "importer" {
      driver = "docker"

      config {
        image = "fireflyiii/data-importer:latest"
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/stack.env"
        env         = true
        data        = file("stack.env")
      }

      resources {
        memory = 200
        cpu    = 200
      }
    }
  }

  group "fints" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "firefly-fints"

      port = 8080

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.fints.rule=Host(`fints.lab.${var.base_domain}`)",
        "traefik.http.routers.fints.entrypoints=websecure"
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
              destination_name = "firefly-server"
              local_bind_port  = 80
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

    task "importer" {
      driver = "docker"

      config {
        image = "benkl/firefly-iii-fints-importer:latest"

        volumes = [ 
          "secrets/giro.json:/data/configurations/giro.json",
          # "secrets/kk_matthias.json:/data/configurations/kk_matthias.json"
        ]
      }

      # updates the transactions of the account(s)
      action "update-transactions" {
        command = "/bin/sh"
        args    = ["-c", <<EOH
echo "updating transactions"
curl -X GET 'http://localhost:8080/?automate=true&config=giro.json'
echo "finished updating transactions"
EOH
        ]
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/giro.json"
        data            = <<EOH
{{- with nomadVar "nomad/jobs/firefly" }}
{
  "bank_username": "{{ .fints_bank_user }}",
  "bank_password": "{{ .fints_bank_password }}",
  "bank_code": "{{ .fints_bank_blz }}",
  "bank_url": "{{ .fints_bank_api_url }}",
  "bank_2fa": "{{ .fints_bank_2fa }}",
  "bank_2fa_device": "",
  "bank_fints_persistence": "",
  "firefly_url": "localhost:80",
  "firefly_access_token": "{{ .importer_token }}",
  "skip_transaction_review": "false",
  "__description_regex_comment__": "To disable the regex search & replace of the transaction description, set both to an empty string.",
  "description_regex_match": "/^(Übertrag \\/ Überweisung|Lastschrift \\/ Belastung)(.*)(END-TO-END-REF.*|Karte.*|KFN.*)(Ref\\..*)$/mi",
  "description_regex_replace": "$2 [$1 | $3 | $4]",
  "auto_submit_form_via_js": "false",
  "choose_account_automation":
  {
    "bank_account_iban": "{{ .fints_firefly_account_iban }}",
    "firefly_account_id": "{{ .fints_firefly_account_id }}",
    "__from_to_comment__": "The following values will be passed directly into DateTime. Set them to null to choose them manually during import process.",
    "from": "now - 7 days",
    "to": "now"
  }
}{{- end }}
EOH
      }

      resources {
        memory = 200
        cpu    = 200
      }
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
find /var/lib/mysql//backup/* -mtime +3 -exec rm {} \;
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
MYSQL_DATABASE = firefly
{{- end }}
EOH
      }

      resources {
        memory = 384
        cpu    = 200
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