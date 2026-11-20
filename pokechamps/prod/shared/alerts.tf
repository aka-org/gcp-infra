# Production's alerts, sent by email: a scheduled job that failed, and the
# API or the web frontend with no ready pod for five minutes. Each policy
# matches the app's namespace in every cluster of the project, so a region
# added later is covered as it is. An alert sends one email when it opens
# and one when it closes; nothing repeats while it stays open.
#
# Every alert links its runbook (the app repository's docs/runbooks/, as
# docs/runbooks/README.md here describes); none is added without one.
#
# The email channel is made by hand (docs/manual-setup.md, "Production's
# alerts") so its address is never in this repository or in state; it is
# found here by its display name.

data "google_monitoring_notification_channel" "alerts" {
  display_name = var.alert_channel_name
}

locals {
  app_namespace = "pokechamps"
  # The app repository's runbooks, one per alert (its docs/runbooks/).
  runbooks = "https://github.com/aka-org/pokechamps/blob/main/docs/runbooks"
  # Every email's subject starts with this, for the mail filter.
  alert_subject = "[vgcrival prod]"
}

# A Job ends failed when its pod fails on its own code (backoffLimit 0),
# runs past activeDeadlineSeconds, or meets a podFailurePolicy rule that
# fails it; the Job controller records each as an event with one of these
# reasons. A pod the cluster stops (preempted, evicted, drained) is
# restarted by the Job's podFailurePolicy and records none of them. Read
# from the cluster's events in Cloud Logging: Google's metrics carry no
# Job status.
resource "google_monitoring_alert_policy" "job_failed" {
  display_name = "${local.alert_subject} Scheduled job failed"
  combiner     = "OR"

  conditions {
    display_name = "A Job in ${local.app_namespace} ended failed"
    condition_matched_log {
      filter = join(" AND ", [
        "logName=\"projects/${var.project_id}/logs/events\"",
        "jsonPayload.involvedObject.kind=\"Job\"",
        "jsonPayload.involvedObject.namespace=\"${local.app_namespace}\"",
        "jsonPayload.reason=(\"BackoffLimitExceeded\" OR \"DeadlineExceeded\" OR \"PodFailurePolicy\")",
      ])
      label_extractors = {
        job = "EXTRACT(jsonPayload.involvedObject.name)"
      }
    }
  }

  alert_strategy {
    # A log-match condition must set how often it may notify: at most one
    # email per 30 minutes, more than the time between two runs of any job
    # failing the same way.
    notification_rate_limit {
      period = "1800s"
    }
    # A failed Job is an event, not a state that clears: the incident
    # closes itself after a day.
    auto_close = "86400s"
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]

  documentation {
    subject   = "${local.alert_subject} Scheduled job failed: $${log.extracted_label.job}"
    mime_type = "text/markdown"
    content   = <<-EOT
      The Job $${log.extracted_label.job} in namespace `${local.app_namespace}` ended failed.

      What to do: the runbook below.
    EOT
    links {
      display_name = "Runbook: a scheduled job failed"
      url          = "${local.runbooks}/job-failed.md"
    }
  }
}

# A Deployment with no available pod serves nothing: the web frontend's
# pages fail, and every page that reads the API fails or hangs. Read from
# GKE's kube-state metrics (Managed Prometheus). Five minutes, fitted on
# production's own readings of 17-20 Nov: while the API was healthy every
# gap lasted 3 minutes or less (a readiness probe failing on a slow
# request); the outages under crawler load lasted 5 to 28.
resource "google_monitoring_alert_policy" "no_ready_pod" {
  display_name = "${local.alert_subject} No ready pod"
  combiner     = "OR"

  conditions {
    display_name = "pokechamps-api or pokechamps-web has no available pod"
    condition_prometheus_query_language {
      query               = "max by (deployment) (kube_deployment_status_replicas_available{namespace=\"${local.app_namespace}\",deployment=~\"pokechamps-(api|web)\"}) < 1"
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]

  documentation {
    subject   = "${local.alert_subject} No ready pod: $${metric.label.deployment}"
    mime_type = "text/markdown"
    content   = <<-EOT
      $${metric.label.deployment} has had no available pod for 5 minutes; the site is down or failing.

      What to do: the runbook below.
    EOT
    links {
      display_name = "Runbook: no ready pod"
      url          = "${local.runbooks}/no-ready-pod.md"
    }
  }
}
