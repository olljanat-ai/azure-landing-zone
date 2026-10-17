# The hub's Azure Monitor Private Link scope (OneK8s design section 21; the user's ask 2026-10-15: no public
# endpoints): Log Analytics and the data collection endpoints reached over Private Link, so that their workspaces and
# endpoints take no public network access. An Azure Monitor private endpoint answers the global Azure Monitor names
# (api.loganalytics.io, *.ods/oms.opinsights.azure.com, *.handler.control.monitor.azure.com ...) for every network
# that resolves through the hub's private link zones - the Firewall's or labfw's DNS proxy - so there is one scope for
# the whole tenant. Access mode Open: a workspace outside the scope stays reachable on its own public endpoint.
#
# In it: labfw's connection log (its workspace and data collection endpoint; the Azure Monitor Agent on the VM
# resolves through the hub) and the environments' workspaces of monitor_private_link.workspace_ids. Readers outside
# Azure come over the labfw VPN (the pool is management: network rule management-to-monitor-private-link).
locals {
  monitor_private_link = var.monitor_private_link.enabled
  monitor_private_link_zones = [
    "privatelink.monitor.azure.com",
    "privatelink.oms.opinsights.azure.com",
    "privatelink.ods.opinsights.azure.com",
    "privatelink.agentsvc.azure-automation.net",
    "privatelink.blob.core.windows.net", # the agents' solution packs
  ]
  monitor_private_link_resources = !local.monitor_private_link ? {} : merge(
    { for id in var.monitor_private_link.workspace_ids : "workspace-${element(split("/", id), length(split("/", id)) - 1)}" => id },
    !(local.labfw && var.labfw.log_analytics.enabled) ? {} : {
      labfw-workspace = module.labfw[0].log_analytics_workspace.id
      labfw-endpoint  = module.labfw[0].log_analytics_workspace.data_collection_endpoint_id
    },
  )
}

resource "azurerm_resource_group" "monitor_private_link" {
  provider = azurerm.connectivity
  count    = local.monitor_private_link ? 1 : 0
  name     = "rg-hub-monitor-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_monitor_private_link_scope" "hub" {
  provider              = azurerm.connectivity
  count                 = local.monitor_private_link ? 1 : 0
  name                  = "ampls-hub-${var.location}"
  resource_group_name   = azurerm_resource_group.monitor_private_link[0].name
  ingestion_access_mode = "Open"
  query_access_mode     = "Open"
  tags                  = var.tags
}

resource "azurerm_monitor_private_link_scoped_service" "hub" {
  provider            = azurerm.connectivity
  for_each            = local.monitor_private_link_resources
  name                = each.key
  resource_group_name = azurerm_resource_group.monitor_private_link[0].name
  scope_name          = azurerm_monitor_private_link_scope.hub[0].name
  linked_resource_id  = each.value
}

resource "azurerm_private_endpoint" "monitor_private_link" {
  count                         = local.monitor_private_link ? 1 : 0
  name                          = "pe-ampls-hub-${var.location}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.management_network.name
  subnet_id                     = azurerm_subnet.management_pe.id
  custom_network_interface_name = "nic-pe-ampls-hub-${var.location}"
  tags                          = var.tags

  private_service_connection {
    name                           = "azuremonitor"
    private_connection_resource_id = azurerm_monitor_private_link_scope.hub[0].id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "hub"
    private_dns_zone_ids = [for zone in local.monitor_private_link_zones : "${module.platform.dns_resource_group_id}/providers/Microsoft.Network/privateDnsZones/${zone}"]
  }

  # The scope's resources first: the endpoint's DNS records include the workspaces' own names
  depends_on = [azurerm_monitor_private_link_scoped_service.hub]
}
