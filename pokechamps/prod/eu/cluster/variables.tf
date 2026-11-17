variable "project_id" {
  description = "The id of the environment's project (in CI, GCP_PROJECT_ID of the project's bootstrap/ci.env, passed as TF_VAR_project_id)"
  type        = string
}
