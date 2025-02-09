variable "base_domain" {
  default = "missing.environment.variable"
}

job "unifi-network" {
  datacenters = ["home"]
  type        = "service"

  group "network" {

    network {
      mode = "bridge"

      port "envoy_metrics_ui" { to = 9102 }
      port "envoy_metrics_inform" { to = 9103 }
      port "envoy_metrics_speedtest" { to = 9104 }

      port "stun" { to = 3478 }         # udp 
      port "discovery" { to = 10001 }   # udp
      port "discovery-l2" { to = 1900 } # udp
    }

    service {
      name = "unifi-network-ui"

      port = 8888 # NGINX proxy endpoint which strips TLS from the connection

      check {
        type            = "http"
        path            = "/status"
        interval        = "10s"
        timeout         = "2s"
        expose          = true
      }

      tags = [
        "traefik.enable=true",
        "traefik.consulcatalog.connect=true",
        "traefik.http.routers.unifi-network.rule=Host(`network.lab.${var.base_domain}`)",
        "traefik.http.routers.unifi-network.entrypoints=websecure"
      ]

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_ui}" 
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9102"
            }
            upstreams {
              destination_name = "unifi-mongodb"
              local_bind_port  = 27017
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

    # Inform port, required to discover Unifi devices on the network
    # Don't forget to set the "Inform Host" in Settings->System->Advanced to your ingress IP (floating IP managed by keepalived)
    service {
      name = "unifi-network-inform"

      port = 8080

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_inform}"
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
            memory = 64
          }
        }
      }
    }

    # Speedtest port
    service {
      name = "unifi-network-speedtest"

      port = 6789

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics_speedtest}"
      }
      connect {
        sidecar_service {
          proxy {
            config {
              envoy_prometheus_bind_addr = "0.0.0.0:9104"
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

    # STUN port (UDP), proxied by NGINX in consul-ingres
    service {
      name = "unifi-network-stun"

      port = "stun"
    }

    # Discovery port (UDP), proxied by NGINX in consul-ingres
    service {
      name = "unifi-network-discovery"

      port = "discovery"
    }

    # Discovery-L2 port (UDP), proxied by NGINX in consul-ingres
    # Used to "Make application discoverable on L2 network" in the UniFi Network settings.
    service {
      name = "unifi-network-discovery-l2"

      port = "discovery-l2"
    }

    task "server" {
      driver = "docker"

      config {
        image = "lscr.io/linuxserver/unifi-network-application:latest"
      }

      template {
        destination = "secrets/variables.env"
        env             = true
        data            = <<EOH
TZ = "Europe/Berlin"

{{- with nomadVar "nomad/jobs/unifi-network" }}
MONGO_HOST = "localhost"
MONGO_PORT = "27017"
MONGO_USER = "unifi"
MONGO_PASS = "{{- .db_pass }}"
MONGO_DBNAME = "unifi"
{{- end }}
EOH
      }

      resources {
        memory = 1024
        cpu    = 400
      }

      volume_mount {
        volume      = "unifi-network"
        destination = "/config"
      }
    }

    volume "unifi-network" {
      type            = "csi"
      source          = "unifi-network"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }


    # NGINX to strip https from the UI endpoint (8443), required to make Consul Connect happy
    task "nginx" {

      driver = "docker"

      config {
        image           = "nginxinc/nginx-unprivileged:alpine"
        volumes         = ["local/nginx.conf:/etc/nginx/conf.d/default.conf"]
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        data        = <<_EOF
map $http_upgrade $connection_upgrade {  
    default upgrade;
    ''      close;
}

server {
  listen 127.0.0.1:8888;

  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  proxy_set_header Host $host;
  proxy_socket_keepalive on;
  client_max_body_size 100m;

  location / {
    proxy_pass https://localhost:8443; # Main Unifi console
  }
}
_EOF
        destination = "local/nginx.conf"
      }

      resources {
        cpu    = 20
        memory = 15
      }
    }
  }


  # MongoDB, which stores metrics and application data
  group "mongodb" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "unifi-mongodb"

      port = 27017

      check {
        type     = "script"
        command  = "sh"
        args     = ["-c", "/usr/bin/mongosh --eval 'db.runCommand(\"ping\").ok'"]
        interval = "10s"
        timeout  = "2s"
        task     = "server"
      }

      meta { # make envoy metrics port available in Consul
        envoy_metrics_port = "${NOMAD_HOST_PORT_envoy_metrics}"
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

      # backs up the MongoDB database and removes all files in the backup folder which are older than 3 days
      action "backup-mongodb" {
        command = "/bin/sh"
        args    = ["-c", <<EOF
mongodump --gzip --archive=/storage/backup/backup.$(date +"%Y%m%d%H%M").gz
echo "cleaning up backup files older than 3 days ..."
find /storage/backup/* -mtime +3 -exec rm {} \;
EOF
        ]
      }

      config {
        image = "mongo:7.0"
        command = "mongod"

        args = ["--config", "/local/mongod.conf"]

        volumes = [
          "secrets/initdb:/docker-entrypoint-initdb.d:ro",
        ]      
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/initdb/init-mongo.js"
        data = <<EOH
{{- with nomadVar "nomad/jobs/unifi-network" }}
db.getSiblingDB("unifi").createUser({user: "unifi", pwd: "{{- .db_pass }}", roles: [{role: "dbOwner", db: "unifi"}]});
db.getSiblingDB("unifi_stat").createUser({user: "unifi", pwd: "{{- .db_pass }}", roles: [{role: "dbOwner", db: "unifi_stat"}]});
{{- end }}
EOH
      }

      template {
        destination = "local/mongod.conf"
        data = <<EOH
net:
  bindIp: 127.0.0.1
storage:
  dbPath: /storage/db
  directoryPerDB: true
  wiredTiger:
    engineConfig:
      directoryForIndexes: true
      journalCompressor: snappy
    collectionConfig:
      blockCompressor: snappy

systemLog:
  verbosity: 0
#  verbosity: 1 # log level Debug1
EOH
      }

      resources {
        memory = 768
        cpu    = 600
      }

      # If using nfs, the share must preserve user:group and not sqash access rights
      volume_mount {
        volume      = "unifi-mongo"
        destination = "/storage"
      }
    }
 
    volume "unifi-mongo" {
      type            = "csi"
      source          = "unifi-mongo"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
