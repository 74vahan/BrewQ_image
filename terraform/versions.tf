terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 9.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
  }

  # State is local by default so `terraform plan` works before any cloud setup.
  # It holds the deploy private key and all application secrets, so for team
  # use put it in a private GCS bucket instead:
  #   1. uncomment the block below
  #   2. terraform init -backend-config=backend.hcl   (see backend.hcl.example)
  #
  # backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
