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

# A release of the site: when a version tag (vX.Y.Z) is pushed to the app
# repository, Cloud Build runs that commit's cloudbuild.yaml -- the facts
# check, the five images, the Helm releases into production -- as the
# account above, once a person has approved the build in the console.
#
# The repository is reached through the connection `github-aka-org`,
# made by hand in the console (it holds GitHub's authorisation, a secret
# Cloud Build keeps in Secret Manager itself), with the repository linked
# to it as `aka-org-pokechamps`.
resource "google_cloudbuild_trigger" "release" {
  project     = var.project_id
  location    = local.region
  name        = "pokechamps-release"
  description = "Builds and deploys a version tag of aka-org/pokechamps to production"

  repository_event_config {
    repository = "projects/${var.project_id}/locations/${local.region}/connections/github-aka-org/repositories/aka-org-pokechamps"
    push {
      tag = "^v[0-9]+\\.[0-9]+\\.[0-9]+$"
    }
  }

  filename        = "cloudbuild.yaml"
  service_account = google_service_account.cloudbuild.id

  # The app repository's main branch can't be protected on GitHub's free
  # plan: nothing reaches production without this approval.
  approval_config {
    approval_required = true
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.push,
    google_project_iam_member.cloudbuild_logs,
  ]
}

# A deploy with no new images: a person runs it (the console's Run, or
# `gcloud builds triggers run pokechamps-deploy --branch main
# --substitutions _VERSION=1.2.3`) when only configuration changed -- the
# app repository's chart or deploy/ values -- and Cloud Build runs main's
# cloudbuild-deploy.yaml: an already-built version's images with main's
# configuration, as the release's own deploy step does. Same account and
# same approval as a release; _VERSION is required (the build stops without
# a version whose images exist).
resource "google_cloudbuild_trigger" "deploy" {
  project     = var.project_id
  location    = local.region
  name        = "pokechamps-deploy"
  description = "Deploys an already-built version of aka-org/pokechamps with main's configuration"

  source_to_build {
    repository = "projects/${var.project_id}/locations/${local.region}/connections/github-aka-org/repositories/aka-org-pokechamps"
    ref        = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  git_file_source {
    path       = "cloudbuild-deploy.yaml"
    repository = "projects/${var.project_id}/locations/${local.region}/connections/github-aka-org/repositories/aka-org-pokechamps"
    revision   = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  substitutions = {
    _VERSION = ""
  }

  service_account = google_service_account.cloudbuild.id

  approval_config {
    approval_required = true
  }
}
