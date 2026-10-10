resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Zone cache rules"
  description = "Entry point ruleset for the http_request_cache_settings phase. Owns every cache rule in the zone."
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      ref         = "cache_static_assets"
      description = "Cache static assets aggressively at the edge and in browsers"
      expression  = "(http.request.uri.path.extension in {\"js\" \"mjs\" \"css\" \"map\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"webp\" \"avif\" \"svg\" \"ico\" \"woff\" \"woff2\" \"ttf\" \"otf\"})"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = var.static_edge_ttl_seconds
        }
        browser_ttl = {
          mode    = "override_origin"
          default = var.static_browser_ttl_seconds
        }
      }
    },
    {
      ref         = "bypass_api"
      description = "Never cache the API. Must stay the LAST rule: when rules conflict, the last matching rule wins."
      expression  = "(http.request.uri.path eq \"/api\" or starts_with(http.request.uri.path, \"/api/\"))"
      action      = "set_cache_settings"
      enabled     = true
      action_parameters = {
        cache = false
      }
    },
  ]
}
