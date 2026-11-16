terraform {
  backend "gcs" {
    bucket = "pokechamps-prod-tfstate-3d8f3f16"
    prefix = "shared"
  }
}
