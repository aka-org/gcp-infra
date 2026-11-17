# Where the site's images are kept, and what builds them: the Artifact
# Registry repository every environment's cluster pulls from, and the
# service account Cloud Build runs as. In the `build` project, outside
# every environment, so an image is built once and the same image runs
# wherever it is deployed.
#
# Applied by CI as this project's Terraform service account, before the
# environments' stages (they grant this stage's build account access to
# their clusters).

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

locals {
  region = "europe-west1"
  # The accounts that pull images: each environment's cluster nodes
  # (terraform-google-gke's node service account).
  image_pullers = [
    "serviceAccount:gke-nodes@${var.prod_project_id}.iam.gserviceaccount.com",
  ]
}

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = local.region
  repository_id = "pokechamps"
  format        = "DOCKER"
  description   = "pokechamps container images, for every environment"

  # Each release adds five images: keep each image's newest ten versions,
  # drop the rest once a month old.
  cleanup_policies {
    id     = "keep-newest"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "pull" {
  for_each = toset(local.image_pullers)

  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

# What Cloud Build runs as: pushes images here, and deploys the Helm
# releases into each environment's clusters (that access is granted in
# the environment's own stages).
resource "google_service_account" "cloudbuild" {
  project      = var.project_id
  account_id   = "cloudbuild-deploy"
  display_name = "Cloud Build: builds and deploys pokechamps"
}

resource "google_artifact_registry_repository_iam_member" "push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Write its build logs.
resource "google_project_iam_member" "cloudbuild_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}
