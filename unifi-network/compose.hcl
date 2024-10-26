job "unifi-network" {
  datacenters = ["home"]
  type        = "service"

  group "network" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      mode = "bridge"

      port "https" { to = 8443 }

      port "stun" { to = 3478 }       # udp 
      port "discovery" { to = 10001 } # udp
      port "discovery-l2" { to = 1900 } # udp
    }

    # Main UI port. Can't get it to work with Consul Connect since the traffic is https
    service {
      name = "unifi-network-https"

      port = "https"

      check {
        type            = "http"
        protocol        = "https"
        tls_skip_verify = true
        path            = "/status"
        interval        = "10s"
        timeout         = "2s"
#        expose          = true
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.unifi-network.rule=Host(`network.lab.schoger.net`)",
        "traefik.http.routers.unifi-network.entrypoints=websecure",
        "traefik.http.services.unifi-network.loadbalancer.server.scheme=https"
      ]
    }

    # Inform port, required to discover Unifi devices on the network
    # Don't forget to set the "Inform Host" in Settings->System->Advanced to your ingress IP (floating IP managed by keepalived)
    service {
      name = "unifi-network-inform"

      port = 8080

      connect {
        sidecar_service {
          proxy {
            config {}
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

      connect {
        sidecar_service {
          proxy {
            config {}
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

    task "network" {
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


    # embedded MongoDB database
    task "mongodb" {
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
        image = "mongo:7.0.14"
        command = "mongod"

        args = ["--config", "/local/mongod.conf"]

        volumes = [
          "secrets/entrypoint:/docker-entrypoint-initdb.d:ro",
        ]      
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "secrets/entrypoint/init-mongo.js"
        data = <<EOH
{{- with nomadVar "nomad/jobs/unifi-network" }}
db.getSiblingDB("unifi").createUser({user: "unifi", pwd: "{{- .db_pass }}", roles: [{role: "dbOwner", db: "unifi"}]});
db.getSiblingDB("unifi_stat").createUser({user: "unifi", pwd: "{{- .db_pass }}", roles: [{role: "dbOwner", db: "unifi_stat"}]});
{{- end }}
EOH
      }

      # If using nfs, the share must preserve user:group and not sqash access rights
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

#systemLog:
#  verbosity: 1 # log level Debug1
EOH
      }

      resources {
        memory = 256
        cpu    = 200
      }

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
