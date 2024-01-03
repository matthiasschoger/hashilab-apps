job "bookstack" {
  datacenters = ["home"]
  type        = "service"

  group "bookstack" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    restart {
      attempts = 3
      delay = "1m"
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "bookstack-ui"

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
        "traefik.http.routers.bookstack-ui.rule=Host(`bookstack.lab.home`)",
        "traefik.http.routers.bookstack-ui.entrypoints=websecure"
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
            upstreams {
              destination_name = "bookstack-mariadb"
              local_bind_port  = 3306
            }
          }
        }

        sidecar_task {
          resources {
            cpu    = 100
            memory = 64
          }
        }
      }
    }

    task "bookstack" {
      driver = "docker"

      config {
        image = "linuxserver/bookstack:latest"
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
{{- with nomadVar "nomad/jobs/bookstack" }}
DB_HOST = "127.0.0.1:3306" 
DB_USER = "bookstack"
DB_PASS = "{{- .db_pass }}"
DB_DATABASE = "bookstackapp"
APP_URL = "https://bookstack.lab.home"
TZ = "Europe/Berlin"
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

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    restart {
      attempts = 3
      delay = "1m"
    }

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "bookstack-mariadb"

      port = 3306

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
            memory = 64
          }
        }
      }
    }

    task "mariadb" {
      driver = "docker"

      config {
        image = "linuxserver/mariadb:latest"
      }

      # health check
      # "/usr/bin/mysql --user=foo --password=foo --execute \"SHOW DATABASES;\""
      
      env {
        MYSQL_ROOT_PASSWORD = "mE9qfGwRy%%NWPULGRU^"
        MYSQL_DATABASE = "bookstackapp"
        MYSQL_USER = "bookstack"
        MYSQL_PASSWORD = "mE9qfGwRy%%NWPULGRU^"
        TZ = "Europe/Berlin"
      }

      resources {
        memory = 200
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