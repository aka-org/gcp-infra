output "image_registry" {
  description = "Where images are pushed and pulled: <this>/<image>:<tag>"
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "cloudbuild_service_account" {
  description = "Email of the service account Cloud Build runs as"
  value       = google_service_account.cloudbuild.email
}

output "release_trigger" {
  description = "Name of the Cloud Build trigger that releases the site"
  value       = google_cloudbuild_trigger.release.name
}
