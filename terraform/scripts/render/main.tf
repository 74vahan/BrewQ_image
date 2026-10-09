# Template rendering without a cloud.
#
# The same templatefile() as in nginx.tf / vm.tf, but the result is written to
# files - so that `nginx -t`, `bash -n` and shellcheck can run over them. There
# is nothing here besides local_file: the google provider is not needed, nor is
# a GCP project or billing.
#
# Run from scripts/check-templates.sh; no need to call it by hand.

terraform {
  required_version = ">= 1.9"

  required_providers {
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }
}

variable "out_dir" {
  description = "Where to put the rendered files"
  type        = string
}

variable "cert_dir" {
  description = "Directory with the certificate (for the check - a self-signed one in a temp dir)"
  type        = string
}

variable "web_root" {
  description = "Panel root"
  type        = string
}

variable "media_dir" {
  description = "Directory with menu images"
  type        = string
}

variable "backend_port" {
  description = "Backend port on loopback"
  type        = number
  default     = 8081
}

locals {
  nginx_template     = "${path.module}/../../nginx/brewq.conf.tftpl"
  bootstrap_template = "${path.module}/../bootstrap.sh.tftpl"

  nginx_common = {
    web_root     = var.web_root
    media_dir    = var.media_dir
    backend_port = var.backend_port
    cert_dir     = var.cert_dir
  }

  domain_names = "brewq.check www.brewq.check"
}

# Three config variants: HTTP on the IP (domain empty, server_name "_"), HTTP
# on the domain (the first certbot pass) and HTTPS with a redirect.
resource "local_file" "http_ip" {
  content         = templatefile(local.nginx_template, merge(local.nginx_common, { tls = false, server_name = "_" }))
  filename        = "${var.out_dir}/http-ip/brewq.conf"
  file_permission = "0644"
}

resource "local_file" "http_domain" {
  content         = templatefile(local.nginx_template, merge(local.nginx_common, { tls = false, server_name = local.domain_names }))
  filename        = "${var.out_dir}/http-domain/brewq.conf"
  file_permission = "0644"
}

resource "local_file" "tls" {
  content         = templatefile(local.nginx_template, merge(local.nginx_common, { tls = true, server_name = local.domain_names }))
  filename        = "${var.out_dir}/tls/brewq.conf"
  file_permission = "0644"
}

# Before templatefile() the bootstrap is a template, not bash, and its syntax
# cannot be checked otherwise. The values are placeholders: what matters is that
# the template expands into a valid script.
resource "local_file" "bootstrap" {
  content = templatefile(local.bootstrap_template, {
    ssh_user                = "brewq"
    app_root                = "/srv/brewq"
    app_dir                 = "/srv/brewq/app"
    web_dir                 = "/srv/brewq/web"
    web_root                = "/srv/brewq/web/current"
    env_file                = "/srv/brewq/.env"
    mysql_database          = "brewq"
    mysql_user              = "brewq"
    mysql_password          = "check-placeholder"
    mysql_root_password     = "check-placeholder"
    barista_password        = "check-placeholder"
    barista_token_secret    = "check-placeholder"
    barista_token_ttl_hours = 12
    backend_port            = 8081
    site_origin             = "http://127.0.0.1"
  })
  filename        = "${var.out_dir}/bootstrap/bootstrap.sh"
  file_permission = "0755"
}
