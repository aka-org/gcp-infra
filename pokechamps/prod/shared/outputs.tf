output "network" {
  description = "Name of the VPC network"
  value       = module.network.network_name
}

output "image_registry" {
  description = "Where images are pushed and pulled: <this>/<image>:<tag>"
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "data_bucket" {
  description = "Name of the data bucket"
  value       = google_storage_bucket.data.name
}

output "data_url" {
  description = "The public address the site reads the data bucket at"
  value       = "https://storage.googleapis.com/${google_storage_bucket.data.name}"
}

output "app_service_account" {
  description = "Email of the service account the HMAC key is created for"
  value       = google_service_account.app.email
}

output "s3_secret" {
  description = "Id of the Secret Manager entry that holds the HMAC key"
  value       = google_secret_manager_secret.s3.secret_id
}

output "cloudbuild_service_account" {
  description = "Email of the service account Cloud Build runs as"
  value       = google_service_account.cloudbuild.email
}

output "web_address" {
  description = "The site's public IP address"
  value       = google_compute_global_address.web.address
}
