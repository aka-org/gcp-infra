# The foundation of pokechamps' `build` project: where the site's images
# are built and kept, outside every environment, so that each environment
# runs the very image another one tested instead of a rebuild of it.
# Holds the project itself, the service account Terraform runs as, the
# state bucket for this project's stages, and the link that lets this
# repository's GitHub Actions act as that service account without a key.
#
# Applied once from a workstation by a person (tools/bootstrap), because
# it creates what CI needs in order to run; the stage beside it
# (pipeline/) is applied by CI.

terraform {
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.11, < 8"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

# Credentials come from the environment (application default credentials
# on a workstation), never from this configuration.
provider "google" {}

module "project" {
  source  = "aka-org/project/google"
  version = "1.4.0"

  # The project id is this name plus a random suffix.
  project_name       = "pokechamps-build"
  billing_account_id = var.billing_account_id
  project_labels = {
    project     = "pokechamps"
    environment = "build"
  }

  # Leave roles/editor as Google grants it.
  remove_editor_members = false

  # What the pipeline stage uses. Secret Manager holds the token of Cloud
  # Build's connection to GitHub, which Cloud Build itself stores there.
  enable_apis = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ]

  # Terraform state of this project's stages, one prefix each.
  bucket_name_prefix = "pokechamps-build-tfstate"
  bucket_location    = "europe-west1"
  # tools/bootstrap writes backend.tf itself, with the stage's prefix.
  gcs_backend = false

  # The service account the pipeline stage is applied as, on top of the
  # module's own roles (IAM, service accounts, APIs, the state bucket,
  # identity pools).
  sa_roles = [
    "roles/artifactregistry.admin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.connectionAdmin",
  ]

  # GitHub Actions of this repository authenticate through Workload
  # Identity Federation: no key exists to leak. Only workflows running for
  # main may act as Terraform's service account; pull requests plan as a
  # second account that can read the project and the state but change
  # nothing.
  gha_wif_enabled   = true
  gha_owner_id      = var.github_owner_id
  gha_allowed_repos = ["aka-org/gcp-infra"]
  gha_sa_refs       = ["refs/heads/main"]
  gha_plan_sa_id    = "terraform-plan"
}
