output "site_url" {
  description = "The site's public address"
  value       = "https://${var.domain}"
}

output "cdn_host" {
  description = "The host the data bucket is served at through Cloudflare"
  value       = "cdn.${var.domain}"
}
