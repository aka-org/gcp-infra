variable "billing_account_id" {
  description = "The billing account the project is charged to. Passed as TF_VAR_billing_account_id, never written to a file in this repository"
  type        = string
  sensitive   = true
}

variable "github_owner_id" {
  description = "The numeric id of the GitHub organisation whose repositories may authenticate (aka-org's; `curl -s https://api.github.com/orgs/aka-org | jq .id`). Passed as TF_VAR_github_owner_id"
  type        = string
}
