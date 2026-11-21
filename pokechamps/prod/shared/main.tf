# What production's regions share, inside the one `prod` project: the
# network (a subnet and a NAT gateway per region), the public data
# bucket (cdn.<domain>), the site's address, the app's service account,
# the empty Secret Manager entries for its storage key and the site's
# certificate, the build project's permission to deploy here, the alerts
# (alerts.tf), and the billing account's budget and cost export
# (billing.tf). Images are not kept here: they come from the `build`
# project's registry (../../build/pipeline).
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

# The identity the sync, teams and reports jobs write the bucket as. Its
# HMAC key (the S3 API's access key and secret) is created by hand and
# stored by hand in the secret below: no key is ever in Terraform state.
resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "pokechamps-app"
  display_name = "pokechamps jobs: writes the data bucket"
}

# The files the jobs publish and the site reads: the data "CDN". Public
# to read, object by object; written only by the app's service account,
# through Cloud Storage's S3-compatible API. The apps read it at Cloud
# Storage's own address; browsers at the site's domain, through
# Cloudflare: it is named after `cdn.<domain>` and served by Cloudflare's
# proxy through Cloud Storage's c.storage.googleapis.com endpoint (../edge),
# which picks a bucket by the request's Host -- the free way to put a
# bucket behind a domain, since Cloudflare overrides a Host only on its
# Enterprise plan. Cloud Storage creates a bucket named after a domain only
# for an account Google knows owns it: Terraform's account is made an owner
# of the domain by hand first (docs/manual-setup.md, "Proving the domain
# to Google").
resource "google_storage_bucket" "cdn" {
  project  = var.project_id
  name     = "cdn.${var.domain}"
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
resource "google_storage_bucket_iam_member" "cdn_public_read" {
  bucket = google_storage_bucket.cdn.name
  role   = "roles/storage.legacyObjectReader"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "cdn_app_objects" {
  bucket = google_storage_bucket.cdn.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Listing and reading the bucket's own metadata, which the S3 API's
# bucket-level calls need.
resource "google_storage_bucket_iam_member" "cdn_app_bucket" {
  bucket = google_storage_bucket.cdn.name
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

# Holds the Discord webhook the reports job posts through: the URL of the
# webhook on the server's announcements channel, which is its own secret
# (anyone holding it can post there). Created empty: the value is added by
# hand (docs/manual-setup.md, "Discord"), and External Secrets copies it
# into the cluster for the reports CronJob.
resource "google_secret_manager_secret" "discord_webhook" {
  project   = var.project_id
  secret_id = "pokechamps-discord-webhook"

  replication {
    user_managed {
      replicas {
        location = local.region_eu
      }
    }
  }
}

# Holds the site's TLS certificate for the load balancer: Cloudflare's
# Origin certificate for the domain and its private key, as JSON
# ({"tls.crt": "<PEM>", "tls.key": "<PEM>"}). Created empty: the value is
# added by hand (docs/manual-setup.md, "Cloudflare"), and External Secrets
# copies it into the cluster as the app Ingress's TLS Secret.
resource "google_secret_manager_secret" "web_tls" {
  project   = var.project_id
  secret_id = "pokechamps-web-tls"

  replication {
    user_managed {
      replicas {
        location = local.region_eu
      }
    }
  }
}

# The site's public address: reserved here so it outlives the load
# balancer, which the app's Ingress creates and names this address in
# (`kubernetes.io/ingress.global-static-ip-name`). Global, so a second
# region's cluster can later sit behind the same address.
resource "google_compute_global_address" "web" {
  project = var.project_id
  name    = "pokechamps-web"
}

# Cloud Build runs in the `build` project as its own service account
# (../../build/pipeline); here it may connect to the clusters and manage
# workloads in them, which is how a release is deployed.
resource "google_project_iam_member" "cloudbuild_deploy" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:cloudbuild-deploy@${var.build_project_id}.iam.gserviceaccount.com"
}
