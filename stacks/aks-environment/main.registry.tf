# Environment ACR (aks-design sections 9 and 10): images and the signed fleet OCI artifact. Private endpoint in the
# backend spoke, no admin user, no anonymous pull. Images are imported by digest from the previous environment.
# Lab (container_registry_sku Basic / Standard): no private endpoint, public endpoint with Entra ID authentication.
locals {
  registry_private = var.container_registry_sku == "Premium"
}

resource "azurerm_container_registry" "this" {
  name                          = "acr${local.env}aks${var.name_suffix}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.shared.name
  sku                           = var.container_registry_sku
  admin_enabled                 = false
  public_network_access_enabled = !local.registry_private
  anonymous_pull_enabled        = false
  data_endpoint_enabled         = local.registry_private
  zone_redundancy_enabled       = local.registry_private
  network_rule_bypass_option    = "AzureServices"
  tags                          = local.tags
}

resource "azurerm_private_endpoint" "registry" {
  count               = local.registry_private ? 1 : 0
  name                = "pe-${azurerm_container_registry.this.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.backend["shared"].id
  tags                = local.tags

  private_service_connection {
    name                           = "registry"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [module.platform.private_dns_zone_ids["acr"]]
  }
}

resource "azurerm_monitor_diagnostic_setting" "registry" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = module.platform.log_analytics_workspace_id

  enabled_log {
    category_group = "audit"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
