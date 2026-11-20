# The foundation of pokechamps' `prod` environment: its own Google Cloud
# project, the service account Terraform runs as, the bucket every stage
# of the environment keeps its state in, and the link that lets this
# repository's GitHub Actions act as that service account without a key.
# The project is not tied to a region: what runs in one region lives in
# that region's folder beside this one (eu/).
#
# Applied once from a workstation by a person (tools/bootstrap), because
# it creates what CI needs in order to run; the other stages are applied
# by CI.

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
  project_name       = "pokechamps-prod"
  billing_account_id = var.billing_account_id
  project_labels = {
    project     = "pokechamps"
    environment = "prod"
  }

  # Leave roles/editor as Google grants it: its members include the Google
  # APIs Service Agent, which creates the VMs of managed instance groups,
  # GKE's nodes among them.
  remove_editor_members = false

  # What the environment's other stages use.
  enable_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "secretmanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "billingbudgets.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ]

  # Terraform state of every stage of this environment, one prefix each.
  # The bucket's own location; the environment's regions are unrelated to it.
  bucket_name_prefix = "pokechamps-prod-tfstate"
  bucket_location    = "europe-west1"
  # tools/bootstrap writes backend.tf itself, with the stage's prefix.
  gcs_backend = false

  # The service account the environment's other stages are applied as,
  # on top of the module's own roles (IAM, service accounts, APIs, the
  # state bucket, identity pools).
  sa_roles = [
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/secretmanager.admin",
    # The alert policies (../shared/alerts.tf), and reading the email
    # channel they send to, made by hand.
    "roles/monitoring.alertPolicyEditor",
    "roles/monitoring.notificationChannelViewer",
    # The billing export's dataset (../shared/billing.tf).
    "roles/bigquery.dataOwner",
  ]

  # GitHub Actions of this repository authenticate as that service account
  # through Workload Identity Federation: no key exists to leak.
  gha_wif_enabled   = true
  gha_owner_id      = var.github_owner_id
  gha_allowed_repos = ["aka-org/gcp-infra"]

  # A pull request's workflow runs the pull request's own workflow file,
  # before review: only workflows running for main may act as Terraform's
  # service account, and pull requests plan as a second account that can
  # read the project and the state but change nothing.
  gha_sa_refs    = ["refs/heads/main"]
  gha_plan_sa_id = "terraform-plan"
}

# The budget (../shared/billing.tf) belongs to the billing account, not the
# project: Terraform's account manages budgets on it, and the plan account
# reads them so a pull request's plan can compare. Granted here because
# only a person with the account's billing administration can.
resource "google_billing_account_iam_member" "terraform_budgets" {
  billing_account_id = var.billing_account_id
  role               = "roles/billing.costsManager"
  member             = "serviceAccount:${module.project.sa_email}"
}

resource "google_billing_account_iam_member" "plan_budgets" {
  billing_account_id = var.billing_account_id
  role               = "roles/billing.viewer"
  member             = "serviceAccount:${module.project.plan_sa_email}"
}
