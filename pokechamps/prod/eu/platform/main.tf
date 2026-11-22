# What runs inside production's EU cluster before any app does: the
# External Secrets Operator, and the cluster-wide store through which it
# reads Google Secret Manager. An app then declares an ExternalSecret and
# gets an ordinary Kubernetes Secret, with no secret value in git, in an
# image or in Terraform state.
#
# Applied by CI as Terraform's service account, after ../cluster.

terraform {
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.11, < 8"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}

provider "google" {
  project = var.project_id
}

data "google_project" "this" {
  project_id = var.project_id
}

data "google_container_cluster" "this" {
  project  = var.project_id
  name     = "prod-eu"
  location = "europe-west1"
}

# Helm reaches the cluster through its DNS endpoint and asks
# gke-gcloud-auth-plugin for a short-lived token at each run: no
# credential is written to state. The plugin must be on the PATH of
# whatever runs Terraform.
provider "helm" {
  kubernetes = {
    host = "https://${data.google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "gke-gcloud-auth-plugin"
    }
  }
}

locals {
  eso_namespace       = "external-secrets"
  eso_service_account = "external-secrets"
  # The operator's Kubernetes service account as Google sees it through
  # Workload Identity: the principal IAM roles are granted to directly.
  eso_principal = "principal://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${local.eso_namespace}/sa/${local.eso_service_account}"
}

# The operator may read the app's storage key, the site's TLS certificate
# and the Discord webhook, and nothing else in Secret Manager: each further
# secret is granted here by name.
resource "google_secret_manager_secret_iam_member" "eso_s3" {
  project   = var.project_id
  secret_id = "pokechamps-s3"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.eso_principal
}

resource "google_secret_manager_secret_iam_member" "eso_web_tls" {
  project   = var.project_id
  secret_id = "pokechamps-web-tls"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.eso_principal
}

resource "google_secret_manager_secret_iam_member" "eso_discord_webhook" {
  project   = var.project_id
  secret_id = "pokechamps-discord-webhook"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.eso_principal
}

resource "google_secret_manager_secret_iam_member" "eso_bluesky_app_password" {
  project   = var.project_id
  secret_id = "pokechamps-bluesky-app-password"
  role      = "roles/secretmanager.secretAccessor"
  member    = local.eso_principal
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = local.eso_namespace
  create_namespace = true

  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "2.14.0"

  # Autopilot bills, and schedules, by what each pod requests.
  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      name = local.eso_service_account
    }
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
    }
    webhook = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
      }
    }
    certController = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
      }
    }
  })]
}

# The ClusterSecretStore is a custom resource, so it can only be sent to
# the cluster once the operator's release has installed its definition:
# a one-template chart of its own, released after the operator.
resource "helm_release" "secret_store" {
  name      = "secret-store"
  namespace = local.eso_namespace
  chart     = "${path.module}/charts/secret-store"

  values = [yamlencode({
    projectId = var.project_id
  })]

  depends_on = [
    helm_release.external_secrets,
    google_secret_manager_secret_iam_member.eso_s3,
    google_secret_manager_secret_iam_member.eso_web_tls,
  ]
}
