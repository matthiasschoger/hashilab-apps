job "unifi-network" {
  datacenters = ["home"]
  type        = "service"

  group "network" {

    constraint {
      attribute = "${node.class}"
      value     = "compute"
    }

    network {
      port "ui" { static = 18443 }        # also changed in /data/system.properties
      port "controller" { static = 8080 }
      port "stun" { static = 3478 }
      port "discovery" { static = 10001 }
      port "discovery-l2" { static = 1900 }
      port "speedtest" { static = 6789 }
    }

    service {
      name = "unifi-network"

      port = "ui"

      check {
        type            = "http"
        protocol        = "https"
        tls_skip_verify = true
        path            = "/status"
        interval        = "10s"
        timeout         = "2s"
      }

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.unifi-network.rule=Host(`network.lab.schoger.net`)",
        "traefik.http.routers.unifi-network.entrypoints=websecure",
        "traefik.http.services.unifi-network.loadbalancer.server.scheme=https"
      ]
    }

    task "network" {
      driver = "docker"

      // user = "1026:100" # matthias:users

      config {
        image = "lscr.io/linuxserver/unifi-network-application:latest"

        network_mode = "host"
        ports = ["ui","controller","stun","discovery","discovery-l2","speedtest"]
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
        memory = 1200
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

      # proper user id is required for MongoDB
      user = "1026:100" # matthias:users

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
        image = "mongo:4.4.29" # latest MongoDB version supported by the Unifi Network application

        args = ["--config", "/local/config.yaml"]

        ports = ["mongodb"]

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
        destination = "local/config.yaml"
        data = <<EOH
storage:
   dbPath: "/storage/db"

#systemLog:
#  verbosity: 1 # log level Debug1
EOH
      }

      resources {
        memory = 700
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
