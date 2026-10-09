# nginx on the host: the single front door for the static panel, the media
# files and the API.
#
# Why here and not in Docker next to the application: the certificate, the
# panel on disk and the media all outlive any single deploy, and a deploy that
# cannot touch nginx cannot break the front door. The price is one ssh round
# trip per config change, paid by `terraform apply`.

locals {
  tls_enabled = var.domain != "" && var.certbot_email != ""

  # Without a domain nginx answers on any name, i.e. on the bare IP.
  server_names = var.domain != "" ? join(" ", concat([var.domain], var.domain_aliases)) : "_"
  cert_dir     = "/etc/letsencrypt/live/${var.domain}"

  nginx_template_vars = {
    server_name  = local.server_names
    web_root     = local.web_root
    media_dir    = local.media_dir
    backend_port = var.backend_port
    cert_dir     = local.cert_dir
  }

  # Two renders of one template. The HTTP one always goes up first: certbot
  # needs a live server on port 80 to answer the ACME challenge, and that
  # cannot happen from a config that already references a missing certificate.
  nginx_site_http = templatefile("${path.module}/nginx/brewq.conf.tftpl", merge(local.nginx_template_vars, { tls = false }))
  nginx_site_tls  = templatefile("${path.module}/nginx/brewq.conf.tftpl", merge(local.nginx_template_vars, { tls = true }))
}

resource "null_resource" "nginx_site" {
  depends_on = [null_resource.wait_for_bootstrap]

  # Re-runs whenever the rendered config changes, and only then:
  # `templatefile` is evaluated at plan time, so the diff shows what will land
  # on the server.
  triggers = {
    site_config = local.nginx_site_http
  }

  connection {
    type        = "ssh"
    host        = google_compute_address.external.address
    user        = var.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.nginx_site_http
    destination = "/tmp/brewq.conf"
  }

  # `nginx -t` before `reload` is the whole point of doing this from Terraform:
  # a broken config fails the apply instead of taking the site down.
  provisioner "remote-exec" {
    inline = [
      "sudo install -m 0644 -o root -g root /tmp/brewq.conf /etc/nginx/sites-available/brewq",
      "sudo ln -sfn /etc/nginx/sites-available/brewq /etc/nginx/sites-enabled/brewq",
      "sudo rm -f /etc/nginx/sites-enabled/default",
      "sudo nginx -t",
      "sudo systemctl reload nginx",
      "rm -f /tmp/brewq.conf",
    ]
  }
}
