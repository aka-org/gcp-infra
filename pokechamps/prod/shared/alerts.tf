# Production's alerts, sent by email: a scheduled job that failed; the API
# or the web frontend with no ready pod for five minutes; the site answering
# server errors; the site unreachable from outside. Each policy
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
  # The load balancer's requests, and its server errors (PromQL names of
  # loadbalancing.googleapis.com/https/request_count).
  lb_requests     = "loadbalancing_googleapis_com:https_request_count{monitored_resource=\"https_lb_rule\"}"
  lb_requests_5xx = "loadbalancing_googleapis_com:https_request_count{monitored_resource=\"https_lb_rule\",response_code_class=\"500\"}"
  # A checker region's last /healthz result, failed (the uptime check's
  # monitoring.googleapis.com/uptime_check/check_passed, one series a region).
  uptime_failing = "monitoring_googleapis_com:uptime_check_check_passed{monitored_resource=\"uptime_url\",check_id=\"${google_monitoring_uptime_check_config.site.uptime_check_id}\"} == 0"
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

# The load balancer answering with server errors: more than 5% of requests
# over 10 minutes, and at least 20 of them, so a handful at night doesn't
# count. Catches what "No ready pod" doesn't -- one pod failing, requests
# timing out -- while every Deployment still reads available. Fitted on
# production's own minutes of 19-20 Nov: it holds through each outage under
# crawler load and 0.2.3's deploy gap, and never on healthy traffic (0-2%
# errors an hour). Read from Google's load-balancer metrics (PromQL).
resource "google_monitoring_alert_policy" "server_errors" {
  display_name = "${local.alert_subject} Site answering errors"
  combiner     = "OR"

  conditions {
    display_name = "More than 5% of requests failing with a server error"
    condition_prometheus_query_language {
      query = join(" ", [
        "(sum(increase(${local.lb_requests_5xx}[10m])) / sum(increase(${local.lb_requests}[10m])) > 0.05)",
        "and (sum(increase(${local.lb_requests_5xx}[10m])) >= 20)",
      ])
      duration            = "300s"
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]

  documentation {
    subject   = "${local.alert_subject} Site answering errors"
    mime_type = "text/markdown"
    content   = <<-EOT
      More than 5% of the site's requests have failed with a server error for 5 minutes.

      What to do: the runbook below.
    EOT
    links {
      display_name = "Runbook: the site answers errors"
      url          = "${local.runbooks}/site-errors.md"
    }
  }
}

# The site as a visitor reaches it: /healthz (the web server alone, no API
# call) through Cloudflare, every minute, from Google's checkers in several
# regions. Catches what Google's own load-balancer metrics can't see,
# because the requests never arrive -- an expired certificate, DNS, a
# Cloudflare-side failure (its 52x errors: the 525s of 19 Nov, while the
# certificate was set up).
resource "google_monitoring_uptime_check_config" "site" {
  display_name = "vgcrival.com /healthz"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  content_matchers {
    content = "ok"
    matcher = "CONTAINS_STRING"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain
    }
  }
}

# Alerts in the minute the site fails as a visitor sees it: 3 or more of
# the 6 checker regions fail at once, or any fails while the load balancer
# answered a 5xx in the last 2 minutes. Google's US checkers fail on their
# own while the site answers (23-24 Nov 2026: single minutes, up to 2
# regions at once, no 5xx), which a region count alone mailed as an outage;
# both real outages had 5xx in the failing minute, one with a single region
# failing (27 Nov). Every failure, false or real, lasted one minute, so the
# rule holds for no duration. Replayed on 20-27 Nov 2026 it fires on the two
# outages only (26 Nov 06:21, 27 Nov 08:43 UTC); pokechamps' scheduled check
# P6 reads the same rule (docs/runbooks/scheduled-checks.md, "Limits").
resource "google_monitoring_alert_policy" "site_unreachable" {
  display_name = "${local.alert_subject} Site unreachable"
  combiner     = "OR"

  conditions {
    display_name = "vgcrival.com/healthz failing from 3+ regions, or with load-balancer 5xx"
    condition_prometheus_query_language {
      query = join(" ", [
        "(count(${local.uptime_failing}) >= 3)",
        "or (count(${local.uptime_failing}) >= 1",
        "and on() sum(increase(${local.lb_requests_5xx}[2m])) > 0)",
      ])
      duration            = "0s"
      evaluation_interval = "60s"
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  notification_channels = [data.google_monitoring_notification_channel.alerts.name]

  documentation {
    subject   = "${local.alert_subject} Site unreachable"
    mime_type = "text/markdown"
    content   = <<-EOT
      https://${var.domain}/healthz failed from 3 or more regions at once, or from any while the load balancer answered errors: visitors can't reach the site.

      What to do: the runbook below.
    EOT
    links {
      display_name = "Runbook: the site is unreachable"
      url          = "${local.runbooks}/site-unreachable.md"
    }
  }
}
