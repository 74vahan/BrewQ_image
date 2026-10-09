# Own VPC + subnet so IP addressing and firewall rules stay under our control
# and do not depend on the project's default network.

resource "google_compute_network" "vpc" {
  name                    = "${var.instance_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.30.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Static internal IP - stable address for future services in the same VPC.
resource "google_compute_address" "internal" {
  name         = "${var.instance_name}-internal-ip"
  subnetwork   = google_compute_subnetwork.subnet.id
  address_type = "INTERNAL"
  region       = var.region
}

# Static external IP - the public address does not change on stop/start, so the
# domain's A record and the SERVER_HOST secret stay valid.
resource "google_compute_address" "external" {
  name         = "${var.instance_name}-external-ip"
  address_type = "EXTERNAL"
  region       = var.region
}

# Only 80 and 443 are public: nginx on the host is the single front door.
# The backend listens on 127.0.0.1:8081 and is unreachable from outside.
resource "google_compute_firewall" "web" {
  name    = "${var.instance_name}-allow-web"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.http_source_ranges
  target_tags   = [var.instance_name]
}

# SSH is what CI/CD uses to deploy. Key authentication only (no passwords).
resource "google_compute_firewall" "ssh" {
  name    = "${var.instance_name}-allow-ssh"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = [var.instance_name]
}

# MySQL is never exposed: it listens only on the Docker network and is not
# published. This rule documents the intent and blocks it explicitly.
resource "google_compute_firewall" "deny_mysql" {
  name     = "${var.instance_name}-deny-mysql"
  network  = google_compute_network.vpc.id
  priority = 900

  deny {
    protocol = "tcp"
    ports    = ["3306"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.instance_name]
}
