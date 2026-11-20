# The billing account's monthly budget and the dataset its costs are
# exported to. Both cover the whole billing account (the `build` project
# and this one); they live here because this is the environment the
# account pays for, and the budget emails the same channel as the alerts
# (alerts.tf).
#
# The export itself is switched on by hand -- Google has no API for it
# (docs/manual-setup.md, "Billing export").

# The billing account the project is charged to, read from the project so
# its id is never written into this repository; marked sensitive so a
# plan's log doesn't print it.
data "google_project" "this" {
  project_id = var.project_id
}

# The Budgets API bills its calls to a project of the caller's choosing;
# this one.
provider "google" {
  alias                 = "billing"
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}

resource "google_billing_budget" "monthly" {
  provider        = google.billing
  billing_account = sensitive(data.google_project.this.billing_account)
  display_name    = "${local.alert_subject} Monthly budget"

  budget_filter {
    calendar_period = "MONTH"
  }

  # A stated amount, kept from the budget made by hand before this stage
  # held one: well above the ~EUR 40-55 a month production is estimated at
  # (list prices of what it requests), so only a runaway cost reaches it.
  amount {
    specified_amount {
      currency_code = "EUR"
      units         = "100"
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [data.google_monitoring_notification_channel.alerts.name]
    # The billing account's administrators are emailed too, as Google does
    # by default: a second route should the channel's address change.
    disable_default_iam_recipients = false
  }
}

# Cloud Billing's export writes the account's daily costs here once it is
# switched on; read with BigQuery (a query this size stays inside the free
# monthly allowance).
resource "google_bigquery_dataset" "billing_export" {
  dataset_id    = "billing_export"
  friendly_name = "Billing export"
  description   = "Cloud Billing's standard usage cost export for the billing account (docs/manual-setup.md, \"Billing export\")."
  location      = "EU"
}
