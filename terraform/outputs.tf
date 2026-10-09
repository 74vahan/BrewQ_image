output "external_ip" {
  description = "Public IP of the server - point the domain's A record here"
  value       = google_compute_address.external.address
}

output "public_url" {
  description = "Public URL of the site - variable PUBLIC_BASE_URL in BrewQ_infra"
  value       = local.site_origin
}

output "ssh_user" {
  description = "User for SSH and deploy - secret SERVER_USER"
  value       = var.ssh_user
}

output "app_root" {
  description = "Application root on the server - variable APP_ROOT"
  value       = var.app_root
}

output "backend_port" {
  description = "Backend port on loopback that nginx proxies to"
  value       = var.backend_port
}

output "private_key_path" {
  description = "Local file of the private SSH key"
  value       = local_sensitive_file.private_key.filename
}

output "deploy_private_key_pem" {
  description = "Private SSH key - goes to the SSH_PRIVATE_KEY secret: terraform output -raw deploy_private_key_pem"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

output "ssh_command" {
  description = "Ready-made connection command"
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ${var.ssh_user}@${google_compute_address.external.address}"
}

output "barista_password" {
  description = "Barista password - the operator hands it to the barista: terraform output -raw barista_password"
  value       = local.barista_password
  sensitive   = true
}

output "github_secrets" {
  description = "Non-secret values for the BrewQ_infra GitHub repository (SSH_PRIVATE_KEY and SSH_KNOWN_HOSTS are handled separately, see scripts/push-github-secrets.sh)"
  value = {
    SERVER_HOST     = google_compute_address.external.address
    SERVER_USER     = var.ssh_user
    APP_ROOT        = var.app_root
    PUBLIC_BASE_URL = local.site_origin
  }
}
