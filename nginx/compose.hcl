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
        path     = "/alive"
        interval = "10s"
        timeout  = "2s"
        expose   = true # required for Connect
      }

      tags = [
        "dmz.enable=true",
        "dmz.consulcatalog.connect=true",
        "dmz.http.routers.nginx.rule=Host(`${var.base_domain}`) || Host(`www.${var.base_domain}`)"
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
# www.domain.tld
server {
    server_name www.${var.base_domain};

    location / {
        root  /usr/share/nginx/content/www.${var.base_domain};
    }

    # show index page as error page
    error_page 400 404 500 502 503 504 /index.html;
    location = /index.html {
        root    /usr/share/nginx/content/www.${var.base_domain};
     }

    location /alive { # for the Consul health check
      default_type text/plain;
      return 200;
    }
}

# redirect from domain.tld to www.domain.tld
server {
        server_name ${var.base_domain};
        return 301 $scheme://www.${var.base_domain}$request_uri;
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