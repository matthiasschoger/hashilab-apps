variable "base_domain" {
  default = "missing.environment.variable"
}

job "nginx" {
  datacenters = ["dmz"]
  type        = "service"

  group "nginx" {

    network {
      mode = "bridge"

      port "envoy_metrics" { to = 9102 }
    }

    service {
      name = "nginx"

      port = 80

      check {
        type     = "http"
        path     = "/alive"  # you need that file on the nginx CSI share 
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.nginx.rule=Host(`schoger.net`) || Host(`www.${var.base_domain}`)",
        "dmz.http.routers.nginx.entrypoints=cloudflare",
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

      config {
        image = "nginx:latest"

        volumes = [ "local/conf.d:/etc/nginx/conf.d" ]      
      }

      env {
        TZ = "Europe/Berlin"
      }

      template {
        destination = "local/conf.d/default.conf"
        change_mode   = "signal"
        change_signal = "SIGHUP"

        data = <<EOH
# www.schoger.net
server {
    server_name www.schoger.net;

    location / {
        root  /usr/share/nginx/content/www.schoger.net;
    }

    # show index page as error page
    error_page 400 404 500 502 503 504 /index.html;
    location = /index.html {
        root    /usr/share/nginx/content/www.schoger.net;
     }
}

# redirect from schoger.net to www.schoger.net
server {
        server_name schoger.net;
        return 301 $scheme://www.schoger.net$request_uri;
}
EOH
      }

      resources {
        memory = 50
        cpu    = 50
      }

      volume_mount {
        volume      = "nginx"
        destination = "/usr/share/nginx/content"
      }
    }

    volume "nginx" {
      type            = "csi"
      source          = "nginx"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
    }

  }
}