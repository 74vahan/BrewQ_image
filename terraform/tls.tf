# HTTPS via Let's Encrypt. Skipped entirely until a domain exists: certbot
# cannot validate an IP address. Without a domain the site works over plain
# HTTP on the server's IP - fine for tests, not for the barista password.

check "tls_inputs" {
  assert {
    condition     = var.domain == "" || var.certbot_email != ""
    error_message = "domain is set but certbot_email is not - a certificate cannot be issued, the site will stay on HTTP."
  }
}

check "plain_http" {
  assert {
    condition     = var.domain != ""
    error_message = "domain is not set: the site works over HTTP on the IP, the barista password and tokens travel in plain text. A domain is required for production."
  }
}

resource "null_resource" "tls" {
  count = local.tls_enabled ? 1 : 0

  # Strict order inside one apply: the HTTP site is already live here, so the
  # ACME webroot challenge has something to answer it.
  depends_on = [null_resource.nginx_site]

  triggers = {
    domains     = local.server_names
    email       = var.certbot_email
    site_config = local.nginx_site_tls
  }

  connection {
    type        = "ssh"
    host        = google_compute_address.external.address
    user        = var.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  provisioner "file" {
    content     = local.nginx_site_tls
    destination = "/tmp/brewq-tls.conf"
  }

  provisioner "file" {
    # certbot renews from a systemd timer; nginx only learns about the new
    # certificate when something reloads it.
    content     = "#!/bin/sh\nsystemctl reload nginx\n"
    destination = "/tmp/reload-nginx.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo certbot certonly --webroot -w /var/www/certbot ${join(" ", [for d in concat([var.domain], var.domain_aliases) : "-d ${d}"])} --email ${var.certbot_email} --agree-tos --no-eff-email --non-interactive --keep-until-expiring",
      "sudo install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy",
      "sudo install -m 0755 -o root -g root /tmp/reload-nginx.sh /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh",
      "sudo install -m 0644 -o root -g root /tmp/brewq-tls.conf /etc/nginx/sites-available/brewq",
      "sudo nginx -t",
      "sudo systemctl reload nginx",
      "rm -f /tmp/brewq-tls.conf /tmp/reload-nginx.sh",
    ]
  }
}
