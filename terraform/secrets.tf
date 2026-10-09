# SSH key pair for deploys (CI/CD and manual access).
#
# Note: the private key ends up in Terraform state, together with every
# application secret. That is why this repository has no deploy pipeline and
# `terraform apply` runs from a laptop - see memory/02-terraform-gcp.md.
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/${var.instance_name}-key.pem"
  file_permission = "0600"
}

# Application secrets: taken from tfvars when provided, generated otherwise,
# so a first apply never needs a human to invent passwords. `special = false`
# keeps them safe for DATABASE_URL and the .env file without any escaping.
resource "random_password" "mysql" {
  length  = 32
  special = false
}

resource "random_password" "mysql_root" {
  length  = 32
  special = false
}

resource "random_password" "barista" {
  length  = 20
  special = false
}

resource "random_password" "barista_token_secret" {
  length  = 64
  special = false
}

locals {
  mysql_password       = var.mysql_password != "" ? var.mysql_password : random_password.mysql.result
  mysql_root_password  = var.mysql_root_password != "" ? var.mysql_root_password : random_password.mysql_root.result
  barista_password     = var.barista_password != "" ? var.barista_password : random_password.barista.result
  barista_token_secret = var.barista_token_secret != "" ? var.barista_token_secret : random_password.barista_token_secret.result

  # The layout both repositories agree on (see the contract table in README.md).
  # BrewQ_infra replaces app/ and adds release directories under web/;
  # everything else here is ours.
  app_dir   = "${var.app_root}/app"
  media_dir = "${var.app_root}/app/media"
  web_dir   = "${var.app_root}/web"
  web_root  = "${var.app_root}/web/current"
  env_file  = "${var.app_root}/.env"

  # PUBLIC_BASE_URL in .env and the value pushed to GitHub: the real public
  # origin, so a wrong value cannot silently point smoke tests at nothing.
  site_origin = local.tls_enabled ? "https://${var.domain}" : (
    var.domain != "" ? "http://${var.domain}" : "http://${google_compute_address.external.address}"
  )
}
