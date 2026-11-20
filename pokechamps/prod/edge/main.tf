# The site's domain at Cloudflare, in front of production: the DNS records,
# the zone's TLS and HTTPS settings, and its rules. Cloudflare's proxy
# answers for every name; behind it:
#   - vgcrival.com    -> the site's load balancer (the global address
#                        `pokechamps-web`, ../shared), over HTTPS checked
#                        against Cloudflare's Origin certificate, which the
#                        app's Ingress serves (the certificate itself is
#                        made and stored by hand: docs/manual-setup.md);
#   - www.            -> redirected to the bare domain;
#   - cdn.            -> the public bucket named after it (`cdn.<domain>`,
#                        ../shared), through Cloud Storage's
#                        c.storage.googleapis.com endpoint, which serves a
#                        bucket by the request's Host.
# Cloudflare caches what the origin's Cache-Control allows (the jobs set
# it per file: a year for sprites and icons, no-cache for data) and never
# caches pages, so nothing here decides freshness.
#
# Nothing secret is in this stage or its state. Cloudflare is reached with
# an API token from the environment (CLOUDFLARE_API_TOKEN): in CI a
# read-only one for plans and an editing one for applies, both GitHub
# secrets (docs/manual-setup.md, "Cloudflare").
#
# Applied by CI after ../shared, which reserves the address and makes the
# bucket.

terraform {
  required_version = ">= 1.11.4"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.11, < 8"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

# The token comes from CLOUDFLARE_API_TOKEN.
provider "cloudflare" {}

data "cloudflare_zone" "site" {
  filter = {
    name = var.domain
  }
}

# The load balancer's address: reserved in ../shared, named in the app's
# Ingress.
data "google_compute_global_address" "web" {
  name = "pokechamps-web"
}

locals {
  zone_id = data.cloudflare_zone.site.zone_id
}

# --- records -------------------------------------------------------------

resource "cloudflare_dns_record" "apex" {
  zone_id = local.zone_id
  name    = var.domain
  type    = "A"
  content = data.google_compute_global_address.web.address
  proxied = true
  ttl     = 1 # automatic: a proxied record's own TTL is Cloudflare's
  comment = "The site: production's load balancer (gcp-infra pokechamps/prod/edge)"
}

# Only there for the proxy to answer the name: the redirect rule below
# sends every request on to the bare domain, so the address is never
# reached (100:: is the discard prefix, Cloudflare's own suggestion for a
# redirect-only name).
resource "cloudflare_dns_record" "www" {
  zone_id = local.zone_id
  name    = "www.${var.domain}"
  type    = "AAAA"
  content = "100::"
  proxied = true
  ttl     = 1
  comment = "Redirected to the bare domain (gcp-infra pokechamps/prod/edge)"
}

resource "cloudflare_dns_record" "cdn" {
  zone_id = local.zone_id
  name    = "cdn.${var.domain}"
  type    = "CNAME"
  content = "c.storage.googleapis.com"
  proxied = true
  ttl     = 1
  comment = "The data bucket cdn.${var.domain} (gcp-infra pokechamps/prod/edge)"
}

# Proves to Google that the domain is ours, which Cloud Storage requires
# before a bucket may be named after it. Google checks again from time to
# time, so the record stays.
resource "cloudflare_dns_record" "google_verification" {
  count   = var.google_site_verification == "" ? 0 : 1
  zone_id = local.zone_id
  name    = var.domain
  type    = "TXT"
  content = "\"${var.google_site_verification}\""
  ttl     = 3600
  comment = "Google Search Console: domain ownership (gcp-infra pokechamps/prod/edge)"
}

# --- TLS and HTTPS ------------------------------------------------------
#
# A zone setting always exists at Cloudflare: Terraform sets its value and
# can't delete it (the provider warns so on every apply). Taking one out of
# this file leaves Cloudflare's value as it was; to undo a setting, set it
# back here instead.

# Cloudflare to the origin over HTTPS with the certificate checked: Full
# (strict). The origin is the load balancer with Cloudflare's Origin
# certificate; cdn. has its own rule below.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = local.zone_id
  setting_id = "ssl"
  value      = "strict"
}

resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = local.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = local.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

# --- rules --------------------------------------------------------------

# www. to the bare domain, path and query kept.
resource "cloudflare_ruleset" "redirects" {
  zone_id = local.zone_id
  name    = "Redirects"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"

  rules = [{
    description = "www to the bare domain"
    expression  = "(http.host eq \"www.${var.domain}\")"
    action      = "redirect"
    action_parameters = {
      from_value = {
        status_code = 301
        target_url = {
          expression = "concat(\"https://${var.domain}\", http.request.uri.path)"
        }
        preserve_query_string = true
      }
    }
  }]
}

# cdn. reaches Cloud Storage, whose certificate names Google's hosts, not
# ours: Full, encrypted without checking the name, for that host only.
resource "cloudflare_ruleset" "config" {
  zone_id = local.zone_id
  name    = "Configuration"
  kind    = "zone"
  phase   = "http_config_settings"

  rules = [{
    description = "cdn: Cloud Storage's certificate names Google's hosts"
    expression  = "(http.host eq \"cdn.${var.domain}\")"
    action      = "set_config"
    action_parameters = {
      ssl = "full"
    }
  }]
}

# Meta's crawler kept requesting the pages computed per request -- /build
# and /matchup read a team from the address, so every team card's link is a
# new page costing the API seconds; /settings/ only sets a cookie and
# redirects there; /card/ answers hover cards' JSON -- although the site's
# robots.txt disallows them: 3,968 /build requests on 20 Nov between 19:00
# and 23:00 UTC, without once fetching robots.txt (ClaudeBot, re-reading it,
# stopped). Blocked on those paths only, so it can still read every page
# robots.txt allows.
resource "cloudflare_ruleset" "firewall" {
  zone_id = local.zone_id
  name    = "Firewall"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    description = "Meta's crawler on pages robots.txt disallows"
    expression = join(" ", [
      "(http.user_agent contains \"meta-externalagent\")",
      "and (starts_with(http.request.uri.path, \"/build\")",
      "or starts_with(http.request.uri.path, \"/matchup\")",
      "or starts_with(http.request.uri.path, \"/settings/\")",
      "or starts_with(http.request.uri.path, \"/card/\"))",
    ])
    action = "block"
  }]
}
