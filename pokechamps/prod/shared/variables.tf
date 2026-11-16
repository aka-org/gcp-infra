variable "project_id" {
  description = "The id of the environment's project (the bootstrap stage's output; in CI the Actions variable GCP_PROJECT_ID, passed as TF_VAR_project_id)"
  type        = string
}
