resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = "quote-api.${var.zone_name}"
  type    = "CNAME"
  content = var.quote_api_origin
  proxied = true
  ttl     = 1
  comment = "Managed by Terraform (iac/cloudflare)"
}

import {
  to = cloudflare_dns_record.legacy_www
  id = "REPLACE_WITH_ZONE_ID/REPLACE_WITH_DNS_RECORD_ID"
}

resource "cloudflare_dns_record" "legacy_www" {
  zone_id = var.zone_id
  name    = "www.${var.zone_name}"
  type    = "CNAME"
  content = var.legacy_www_target
  proxied = true
  ttl     = 1
}
