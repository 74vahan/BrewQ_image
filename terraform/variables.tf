# ---------------------------------------------------------------- GCP

variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west3"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west3-c"
}

variable "instance_name" {
  description = "VM name and prefix for all network resources"
  type        = string
  default     = "brewq-server"
}

variable "machine_type" {
  description = "Machine type (e2-small is enough to start, e2-medium gives headroom)"
  type        = string
  default     = "e2-small"
}

variable "disk_size_gb" {
  description = "Boot disk size, GB (the MySQL volume lives on it too)"
  type        = number
  default     = 20
}

# ---------------------------------------------------------------- Access

variable "ssh_user" {
  description = "User for SSH and owner of /srv/brewq. Matches the SERVER_USER secret in BrewQ_infra."
  type        = string
  default     = "brewq"
}

variable "ssh_source_ranges" {
  description = "CIDRs allowed to reach SSH (22). Open by default - needed by GitHub-hosted runners (key-only login); narrow it when hardening."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "http_source_ranges" {
  description = "CIDRs allowed to reach HTTP/HTTPS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------- Contract with BrewQ_infra
# Two integration points: the path on disk and the backend port on loopback.
# The defaults match the deploy defaults and docker-compose.yml.

variable "app_root" {
  description = "Application root on the server. Must match APP_ROOT in the BrewQ_infra CI."
  type        = string
  default     = "/srv/brewq"

  validation {
    condition     = startswith(var.app_root, "/") && !endswith(var.app_root, "/")
    error_message = "app_root must be an absolute path without a trailing slash, e.g. /srv/brewq."
  }
}

variable "backend_port" {
  description = "Backend port on 127.0.0.1 that nginx proxies to. Must match BACKEND_PORT in compose."
  type        = number
  default     = 8081
}

# ---------------------------------------------------------------- Domain and TLS

variable "domain" {
  description = "Site domain, e.g. brewq.example.com. Empty - the site works over HTTP on the IP (for tests only: the barista password travels in plain text)."
  type        = string
  default     = ""

  validation {
    condition     = var.domain == "" || can(regex("^[a-z0-9.-]+[.][a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase domain name without scheme and slash (e.g. brewq.example.com)."
  }
}

variable "domain_aliases" {
  description = "Additional names in the certificate, e.g. [\"www.brewq.example.com\"]. The A records must already point to the server."
  type        = list(string)
  default     = []
}

variable "certbot_email" {
  description = "Email for Let's Encrypt (expiry notices). HTTPS is not enabled without it."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- Application secrets and .env
# An empty value - Terraform generates a random one. Values set by hand end up
# in .env and in DATABASE_URL, so only characters that need no escaping in
# either .env or a URL are allowed.

variable "mysql_database" {
  description = "MySQL database name"
  type        = string
  default     = "brewq"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,31}$", var.mysql_database))
    error_message = "mysql_database: lowercase Latin letters, digits and _, at most 32 characters."
  }
}

variable "mysql_user" {
  description = "MySQL user"
  type        = string
  default     = "brewq"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,31}$", var.mysql_user))
    error_message = "mysql_user: lowercase Latin letters, digits and _, at most 32 characters."
  }

  validation {
    condition     = var.mysql_user != "root"
    error_message = "mysql_user cannot be root: that user is created by the MySQL image separately from MYSQL_ROOT_PASSWORD."
  }
}

variable "mysql_password" {
  description = "MySQL user password. Empty - random."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]*$", var.mysql_password))
    error_message = "mysql_password: only A-Z a-z 0-9 _ . ~ - (otherwise DATABASE_URL would need escaping)."
  }
}

variable "mysql_root_password" {
  description = "MySQL root password. Empty - random."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]*$", var.mysql_root_password))
    error_message = "mysql_root_password: only A-Z a-z 0-9 _ . ~ -"
  }
}

variable "barista_password" {
  description = "Shared barista password. Empty - random (terraform output -raw barista_password)."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.barista_password == "" || length(var.barista_password) >= 12
    error_message = "barista_password must be at least 12 characters (or empty, then it will be generated)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]*$", var.barista_password))
    error_message = "barista_password: only A-Z a-z 0-9 _ . ~ - (the value goes into .env without escaping)."
  }
}

variable "barista_token_secret" {
  description = "Barista token signing secret. Empty - random."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.barista_token_secret == "" || length(var.barista_token_secret) >= 32
    error_message = "barista_token_secret must be at least 32 characters (or empty, then it will be generated)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_.~-]*$", var.barista_token_secret))
    error_message = "barista_token_secret: only A-Z a-z 0-9 _ . ~ -"
  }
}

variable "barista_token_ttl_hours" {
  description = "Barista token lifetime in hours"
  type        = number
  default     = 12

  validation {
    condition     = var.barista_token_ttl_hours >= 1 && var.barista_token_ttl_hours <= 168
    error_message = "barista_token_ttl_hours must be between 1 and 168."
  }
}
