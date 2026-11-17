# Production's cluster in europe-west1: GKE Autopilot on the shared
# network's `eu-nodes` subnet (../../shared, applied first).
#
# Applied by CI as Terraform's service account.

terraform {
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.11, < 8"
    }
  }
}

provider "google" {
  project = var.project_id
}

module "gke" {
  source  = "aka-org/gke/google"
  version = "0.1.0"

  project_id = var.project_id
  name       = "prod-eu"
  location   = "europe-west1"
  mode       = "autopilot"

  # Names from the shared stage.
  network             = "main"
  subnetwork          = "eu-nodes"
  pods_range_name     = "eu-pods"
  services_range_name = "eu-services"

  # No address range is admitted to the control plane's IP endpoint;
  # people and Cloud Build connect through its DNS endpoint, where IAM
  # decides (roles/container.developer or above).
  dns_endpoint_external = true

  # Only what a node needs to run and report. Images come from the build
  # project's registry, which grants these nodes read access itself
  # (../../../build/pipeline).
  node_service_account_roles = ["roles/container.defaultNodeServiceAccount"]

  labels = {
    project     = "pokechamps"
    environment = "prod"
  }
}
