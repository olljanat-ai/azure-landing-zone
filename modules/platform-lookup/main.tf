# Looks up what the platform landing zone (./platform, ALZ accelerator) created, by the names configured in
# accelerator/config/platform-landing-zone.tfvars. Name lookups keep the AKS stacks independent of the
# platform state file and of the output shapes of the ALZ modules.
locals {
  hub_resource_group_name        = "rg-hub-${var.location}"
  dns_resource_group_name        = "rg-hub-dns-${var.location}"
  management_resource_group_name = "rg-management-${var.location}"

  private_dns_zone_names = merge({
    key_vault  = "privatelink.vaultcore.azure.net"
    acr        = "privatelink.azurecr.io"
    blob       = "privatelink.blob.core.windows.net"
    aks        = "privatelink.${var.location}.azmk8s.io"
    monitor    = "privatelink.monitor.azure.com"
    oms        = "privatelink.oms.opinsights.azure.com"
    ods        = "privatelink.ods.opinsights.azure.com"
    agentsvc   = "privatelink.agentsvc.azure-automation.net"
    prometheus = "privatelink.${var.location}.prometheus.monitor.azure.com"
    postgres   = "privatelink.postgres.database.azure.com"
    sql        = "privatelink.database.windows.net"
    servicebus = "privatelink.servicebus.windows.net"
  }, var.private_dns_zone_names)
}

data "azurerm_subscription" "connectivity" {
  provider = azurerm.connectivity
}

data "azurerm_virtual_network" "hub" {
  provider            = azurerm.connectivity
  name                = "vnet-hub-${var.location}"
  resource_group_name = local.hub_resource_group_name
}

data "azurerm_firewall" "hub" {
  provider            = azurerm.connectivity
  name                = "fw-hub-${var.location}"
  resource_group_name = local.hub_resource_group_name
}

data "azurerm_firewall_policy" "hub" {
  provider            = azurerm.connectivity
  name                = "fwp-hub-${var.location}"
  resource_group_name = local.hub_resource_group_name
}

data "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  provider                = azurerm.connectivity
  name                    = "dns" # default inbound endpoint of avm-ptn-alz-connectivity-hub-and-spoke-vnet
  private_dns_resolver_id = "${data.azurerm_subscription.connectivity.id}/resourceGroups/${local.hub_resource_group_name}/providers/Microsoft.Network/dnsResolvers/pdr-hub-dns-${var.location}"
}

data "azurerm_private_dns_zone" "hub" {
  provider            = azurerm.connectivity
  for_each            = { for k, v in local.private_dns_zone_names : k => v }
  name                = each.value
  resource_group_name = local.dns_resource_group_name
}

data "azurerm_log_analytics_workspace" "management" {
  provider            = azurerm.management
  name                = "law-management-${var.location}"
  resource_group_name = local.management_resource_group_name
}
