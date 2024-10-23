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

      port "discovery-l2" { static = 1900 }
      port "speedtest" { static = 6789 }

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "unifi-network-https"

      port = "https"
#      port = 8443

      check {
        type     = "tcp"
        interval = "5s"
        timeout  = "5s"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.unifi-network.rule=Host(`network.lab.schoger.net`)",
        "traefik.http.routers.unifi-network.entrypoints=websecure",
        "traefik.http.services.unifi-network.loadbalancer.server.scheme=https"
      ]
    }

    service {
      name = "unifi-network-inform"

      port = 8080

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

    # STUN port (UDP), tunneled by NGINX in consul-ingres
    service {
      name = "unifi-network-stun"

      port = "stun"
    }

    # Discover port (UDP), tunneled by NGINX in consul-ingres
    service {
      name = "unifi-network-discovery"

      port = "discovery"
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
MONGO_PORT = "27017"
MONGO_HOST = "unifi-mongodb.service.consul"
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
  }


  group "mongodb" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      mode = "bridge"

      port "mongodb" { static = 27017 }
    }

    service {
      name = "unifi-mongodb"

      port = "mongodb"
    }

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

      volume_mount {
        volume      = "unifi-mongo"
        destination = "/storage"
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
#  bindIp: 127.0.0.1
  bindIp: 0.0.0.0
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
    }
 
    volume "unifi-mongo" {
      type            = "csi"
      source          = "unifi-mongo"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }
  }
}
