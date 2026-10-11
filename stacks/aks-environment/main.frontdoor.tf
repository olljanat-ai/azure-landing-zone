# Azure Front Door Premium: cell router of the external zones (aks-design section 8). One profile per environment
# with one endpoint and one WAF policy per ext-* zone (open question: profile per zone). The origin groups – one
# per cell with Private Link origins on the Traefik internal load balancers – are added by the cell stack.
# Off in the lab (front_door_enabled).
locals {
  external_zones = { for z, v in local.zones : z => v if v.exposure == "ext" }
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  count                    = var.front_door_enabled ? 1 : 0
  name                     = "afd-aks-${local.env}"
  resource_group_name      = azurerm_resource_group.shared.name
  sku_name                 = "Premium_AzureFrontDoor"
  response_timeout_seconds = 60
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_firewall_policy" "zone" {
  for_each                   = var.front_door_enabled ? local.external_zones : {}
  name                       = "waf${local.env}${replace(each.key, "-", "")}"
  resource_group_name        = azurerm_resource_group.shared.name
  sku_name                   = "Premium_AzureFrontDoor"
  enabled                    = true
  mode                       = local.enforce ? "Prevention" : "Detection"
  request_body_check_enabled = true
  tags                       = merge(local.tags, { zone = each.key })

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.1"
    action  = "Block"
  }
}

resource "azurerm_cdn_frontdoor_endpoint" "zone" {
  for_each                 = var.front_door_enabled ? local.external_zones : {}
  name                     = "afd-${local.env}-${each.key}-${var.name_suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id
  tags                     = merge(local.tags, { zone = each.key })
}

resource "azurerm_cdn_frontdoor_security_policy" "zone" {
  for_each                 = var.front_door_enabled ? local.external_zones : {}
  name                     = "secpol-${each.key}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.zone[each.key].id
      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.zone[each.key].id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "front_door" {
  count                      = var.front_door_enabled ? 1 : 0
  name                       = "diag-to-law"
  target_resource_id         = azurerm_cdn_frontdoor_profile.this[0].id
  log_analytics_workspace_id = module.platform.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }
}
