# What production's regions share, inside the one `prod` project: the
# network (a subnet and a NAT gateway per region), the image registry,
# the public data bucket, the app's and Cloud Build's service accounts,
# and the empty Secret Manager entry for the app's storage key.
#
# Applied by CI as Terraform's service account, before any region's
# stages. Adding a region is a new subnet and NAT entry here, then that
# region's own folder beside this one.

terraform {
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.11, < 8"
    }
  }
}

# Credentials come from the environment: Workload Identity Federation in
# CI, application default credentials on a workstation.
provider "google" {
  project = var.project_id
}

locals {
  region_eu = "europe-west1"
}

module "network" {
  source  = "aka-org/network/google"
  version = "0.2.0"

  project_id   = var.project_id
  network_name = "main"

  # One subnet per region, each with the two secondary ranges its GKE
  # cluster takes pod and Service addresses from. Ranges are spaced so a
  # second region's fit beside them (10.16.0.0/20, 10.20.0.0/14,
  # 10.24.0.0/20 are free for it).
  subnetworks = [{
    name                     = "eu-nodes"
    region                   = local.region_eu
    ip_cidr_range            = "10.0.0.0/20"
    private_ip_google_access = true
    secondary_ip_ranges = [
      { range_name = "eu-pods", ip_cidr_range = "10.4.0.0/14" },
      { range_name = "eu-services", ip_cidr_range = "10.8.0.0/20" },
    ]
  }]

  # Nodes have no external address: their way out to the internet (the
  # sync's downloads, images hosted outside Google).
  nat_gateways = [{
    name       = "eu"
    region     = local.region_eu
    log_errors = true
  }]
}

# The container images Cloud Build pushes and the clusters pull.
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = local.region_eu
  repository_id = "pokechamps"
  format        = "DOCKER"
  description   = "pokechamps container images"

  # Every push to main adds five images: keep each image's newest ten
  # versions, drop the rest once a month old.
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

# The files the jobs publish and the site reads: the data "CDN". Public
# to read, object by object; written only by the app's service account,
# through Cloud Storage's S3-compatible API.
resource "google_storage_bucket" "data" {
  project  = var.project_id
  name     = "${var.project_id}-data"
  location = upper(local.region_eu)

  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"

  # Browsers fetch these files from the site's own pages.
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type", "Cache-Control", "ETag"]
    max_age_seconds = 3600
  }
}

# Anyone may fetch an object by its name; nobody may list the bucket.
resource "google_storage_bucket_iam_member" "data_public_read" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}

# The identity the sync, teams and reports jobs write the bucket as. Its
# HMAC key (the S3 API's access key and secret) is created by hand and
# stored by hand in the secret below: no key is ever in Terraform state.
resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "pokechamps-app"
  display_name = "pokechamps jobs: writes the data bucket"
}

resource "google_storage_bucket_iam_member" "app_objects" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Listing and reading the bucket's own metadata, which the S3 API's
# bucket-level calls need.
resource "google_storage_bucket_iam_member" "app_bucket" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Holds the app's HMAC key as JSON ({"access-key": ..., "secret-key":
# ...}). Created empty: the value is added with `gcloud secrets versions
# add`, and External Secrets copies it into the cluster.
resource "google_secret_manager_secret" "s3" {
  project   = var.project_id
  secret_id = "pokechamps-s3"

  replication {
    user_managed {
      replicas {
        location = local.region_eu
      }
    }
  }
}

# What Cloud Build runs as: pushes images, deploys the Helm releases.
resource "google_service_account" "cloudbuild" {
  project      = var.project_id
  account_id   = "cloudbuild-deploy"
  display_name = "Cloud Build: builds and deploys pokechamps"
}

resource "google_artifact_registry_repository_iam_member" "cloudbuild_push" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_project_iam_member" "cloudbuild" {
  for_each = toset([
    # Connect to the clusters and manage workloads in them.
    "roles/container.developer",
    # Write its build logs.
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}
