variable "project_id" {
  description = "The id of the environment's project (in CI, GCP_PROJECT_ID of ../bootstrap/ci.env, passed as TF_VAR_project_id)"
  type        = string
}

variable "build_project_id" {
  description = "The id of the build project, whose Cloud Build account deploys here (in CI, from pokechamps/build/bootstrap/ci.env, passed as TF_VAR_build_project_id)"
  type        = string
}

variable "domain" {
  description = "The site's domain (its zone is ../edge's); the data bucket at cdn.<domain> is named after it"
  type        = string
  default     = "vgcrival.com"
}

variable "alert_channel_name" {
  description = "Display name of the email notification channel made by hand for production's alerts (docs/manual-setup.md, \"Production's alerts\")"
  type        = string
  default     = "vgcrival prod alerts"
}
