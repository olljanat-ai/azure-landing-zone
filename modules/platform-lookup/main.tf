# Looks up what the platform landing zone (./platform, ALZ accelerator) created, by the names configured in
# accelerator/config/platform-landing-zone.tfvars. Name lookups keep the AKS stacks independent of the
# platform state file and of the output shapes of the ALZ modules.
locals {
  hub_resource_group_name        = "rg-hub-${var.location}"
  dns_resource_group_name        = "rg-hub-dns-${var.location}"
  management_resource_group_name = "rg-management-${var.location}"

  # Private link zones the AKS stacks use. The hub only has these in the lab (private_link_private_dns_zones in
  # accelerator/config/platform-landing-zone.tfvars); add a zone there and here before a stack needs it.
  private_dns_zone_names = merge({
    key_vault = "privatelink.vaultcore.azure.net"
    acr       = "privatelink.azurecr.io"
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
  count               = var.network_mode == "firewall" ? 1 : 0
  name                = "fw-hub-${var.location}"
  resource_group_name = local.hub_resource_group_name
}

data "azurerm_firewall_policy" "hub" {
  provider            = azurerm.connectivity
  count               = var.network_mode == "firewall" ? 1 : 0
  name                = "fwp-hub-${var.location}"
  resource_group_name = local.hub_resource_group_name
}

# Every private DNS zone of the hub (the private link zones). In
# sandbox mode there is no DNS server in the hub: each spoke links its VNet to all of them and uses Azure DNS.
data "azurerm_resources" "private_dns_zones" {
  provider            = azurerm.connectivity
  resource_group_name = local.dns_resource_group_name
  type                = "Microsoft.Network/privateDnsZones"
}

data "azurerm_private_dns_zone" "hub" {
  provider            = azurerm.connectivity
  for_each            = { for k, v in local.private_dns_zone_names : k => v }
  name                = each.value
  resource_group_name = local.dns_resource_group_name
}
