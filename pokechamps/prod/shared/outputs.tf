output "network" {
  description = "Name of the VPC network"
  value       = module.network.network_name
}

output "data_bucket" {
  description = "Name of the data bucket"
  value       = google_storage_bucket.data.name
}

output "data_url" {
  description = "The public address the site reads the data bucket at"
  value       = "https://storage.googleapis.com/${google_storage_bucket.data.name}"
}

output "cdn_bucket" {
  description = "Name of the data bucket at the site's domain"
  value       = google_storage_bucket.cdn.name
}

output "cdn_url" {
  description = "The public address the site reads the data bucket at, through Cloudflare"
  value       = "https://${google_storage_bucket.cdn.name}"
}

output "app_service_account" {
  description = "Email of the service account the HMAC key is created for"
  value       = google_service_account.app.email
}

output "s3_secret" {
  description = "Id of the Secret Manager entry that holds the HMAC key"
  value       = google_secret_manager_secret.s3.secret_id
}

output "web_address" {
  description = "The site's public IP address"
  value       = google_compute_global_address.web.address
}
