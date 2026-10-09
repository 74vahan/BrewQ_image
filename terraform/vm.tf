resource "google_compute_instance" "server" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [var.instance_name]

  labels = {
    app = "brewq"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    network_ip = google_compute_address.internal.address

    access_config {
      nat_ip = google_compute_address.external.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${tls_private_key.ssh.public_key_openssh}"

    # With OS Login enabled by an organization policy the ssh-keys metadata is
    # ignored and the deploy key would never be installed.
    enable-oslogin = "FALSE"

    # Installs Docker, nginx and certbot, hardens SSH, lays out /srv/brewq
    # and writes .env once.
    startup-script = templatefile("${path.module}/scripts/bootstrap.sh.tftpl", {
      ssh_user                = var.ssh_user
      app_root                = var.app_root
      app_dir                 = local.app_dir
      web_dir                 = local.web_dir
      web_root                = local.web_root
      env_file                = local.env_file
      mysql_database          = var.mysql_database
      mysql_user              = var.mysql_user
      mysql_password          = local.mysql_password
      mysql_root_password     = local.mysql_root_password
      barista_password        = local.barista_password
      barista_token_secret    = local.barista_token_secret
      barista_token_ttl_hours = var.barista_token_ttl_hours
      backend_port            = var.backend_port
      site_origin             = local.site_origin
    })
  }

  # The database lives in a Docker volume on this disk and .env is written
  # once: recreating the VM is a conscious act, not a side effect of editing a
  # script.
  lifecycle {
    ignore_changes = [metadata["startup-script"]]
  }

  service_account {
    # No cloud API access by default - the app only needs the network.
    scopes = ["https://www.googleapis.com/auth/logging.write"]
  }

  allow_stopping_for_update = true
}

# Waits until the startup script finished, so nginx.tf and any deploy right
# after `apply` do not race with the package installation. Up to 15 minutes.
resource "null_resource" "wait_for_bootstrap" {
  depends_on = [google_compute_instance.server]

  triggers = {
    instance_id = google_compute_instance.server.id
  }

  connection {
    type        = "ssh"
    host        = google_compute_address.external.address
    user        = var.ssh_user
    private_key = tls_private_key.ssh.private_key_pem
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'waiting for bootstrap...'",
      "for i in $(seq 1 90); do [ -f ${var.app_root}/.bootstrap-done ] && break; sleep 10; done",
      "test -f ${var.app_root}/.bootstrap-done || { echo 'bootstrap did not finish'; exit 1; }",
      "docker --version",
      "nginx -v",
    ]
  }
}
