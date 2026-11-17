output "project_id" {
  description = "The id of the environment's project"
  value       = module.project.project_id
}

output "project_number" {
  description = "The project's number"
  value       = module.project.project_number
}

output "state_bucket" {
  description = "The bucket holding every stage's Terraform state"
  value       = module.project.bucket_name
}

output "terraform_service_account" {
  description = "Email of the service account the other stages are applied as, from main only"
  value       = module.project.sa_email
}

output "plan_service_account" {
  description = "Email of the read-only service account pull requests plan as"
  value       = module.project.plan_sa_email
}

output "workload_identity_provider" {
  description = "Full name of the identity provider this repository's Actions authenticate through"
  value       = one(module.project.identity_provider_github_full_ids)
}
