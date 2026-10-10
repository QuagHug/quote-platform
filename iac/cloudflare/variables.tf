variable "zone_id" {
  description = "Cloudflare zone ID of example.com (Dashboard > Overview > API > Zone ID). Not a secret."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.zone_id))
    error_message = "zone_id must be the 32-character hex zone ID."
  }
}

variable "zone_name" {
  description = "Apex domain of the zone."
  type        = string
  default     = "example.com"
}

variable "quote_api_origin" {
  description = "Hostname of the origin load balancer that quote-api.example.com points at (for example the EKS ingress NLB/ALB DNS name)."
  type        = string
  default     = "quote-api-origin.example.net"
}

variable "legacy_www_target" {
  description = "Current CNAME target of the manually created www record. Must match what is live today so the import plans with zero changes."
  type        = string
  default     = "example.com"
}

variable "static_edge_ttl_seconds" {
  description = "How long Cloudflare's edge keeps static assets. Purge on deploy if file names are not content-hashed."
  type        = number
  default     = 2592000
}

variable "static_browser_ttl_seconds" {
  description = "How long browsers keep static assets. A Cloudflare purge cannot reach browser caches, so keep this shorter than the edge TTL."
  type        = number
  default     = 86400
}
