terraform {
  backend "gcs" {
    bucket = "pokechamps-build-tfstate-15ebe5e2"
    prefix = "pipeline"
  }
}
