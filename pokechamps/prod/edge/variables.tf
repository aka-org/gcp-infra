variable "project_id" {
  description = "The id of the environment's project (in CI, GCP_PROJECT_ID of the project's bootstrap/ci.env, passed as TF_VAR_project_id)"
  type        = string
}

variable "domain" {
  description = "The site's domain: a zone in the Cloudflare account the API token belongs to"
  type        = string
  default     = "vgcrival.com"
}

variable "google_site_verification" {
  description = "The TXT value Google Search Console gives for proving the domain is ours (google-site-verification=...): public, as every DNS record is. Empty: no record"
  type        = string
  default     = "google-site-verification=75gAxjZtCLXdekgqiDL5A_NZzMNEoYDdDKXk-Koq1kw"
}
