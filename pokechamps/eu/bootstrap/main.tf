# The foundation of pokechamps' `eu` environment: its own Google Cloud
# project, the service account Terraform runs as, the bucket every stage
# of the environment keeps its state in, and the link that lets this
# repository's GitHub Actions act as that service account without a key.
#
# Applied once from a workstation by a person (tools/bootstrap), because
# it creates what CI needs in order to run; the stages beside it
# (cluster/, platform/) are applied by CI.

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
  version = "1.3.0"

  # The project id is this name plus a random suffix.
  project_name       = "pokechamps-eu"
  billing_account_id = var.billing_account_id
  project_labels = {
    project     = "pokechamps"
    environment = "eu"
  }

  # What the environment's other stages use.
  enable_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ]

  # Terraform state of every stage of this environment, one prefix each.
  bucket_name_prefix = "pokechamps-eu-tfstate"
  bucket_location    = "europe-west1"
  # tools/bootstrap writes backend.tf itself, with the stage's prefix.
  gcs_backend = false

  # The service account the cluster/ and platform/ stages are applied as,
  # on top of the module's own roles (IAM, service accounts, APIs, the
  # state bucket, identity pools).
  sa_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.connectionAdmin",
  ]

  # GitHub Actions of this repository authenticate as that service account
  # through Workload Identity Federation: no key exists to leak.
  gha_wif_enabled   = true
  gha_owner_id      = var.github_owner_id
  gha_allowed_repos = ["aka-org/gcp-infra"]
}
