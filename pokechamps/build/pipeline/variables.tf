variable "project_id" {
  description = "The id of the build project (in CI, GCP_PROJECT_ID of ../bootstrap/ci.env, passed as TF_VAR_project_id)"
  type        = string
}

variable "prod_project_id" {
  description = "The id of the prod project, whose cluster nodes pull the images (in CI, from pokechamps/prod/bootstrap/ci.env, passed as TF_VAR_prod_project_id)"
  type        = string
}
