output "name" {
  description = "The cluster's name"
  value       = module.gke.name
}

output "location" {
  description = "The cluster's region"
  value       = module.gke.location
}

output "dns_endpoint" {
  description = "The control plane's DNS endpoint"
  value       = module.gke.dns_endpoint
}

output "get_credentials" {
  description = "The command that adds the cluster to a kubeconfig"
  value       = "gcloud container clusters get-credentials ${module.gke.name} --location ${module.gke.location} --dns-endpoint --project ${var.project_id}"
}
