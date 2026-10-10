# Admin and CI/CD access to the private API server only from the management VNet (aks-design section 3, R1):
# a Private Link Service on the kube-apiserver internal load balancer in snet-apiserver-pls, a private endpoint
# in the management VNet's snet-aks-api-pe and a private DNS zone for the cluster's private FQDN that points to
# that endpoint. Pattern: https://learn.microsoft.com/azure/aks/private-apiserver-vnet-integration-cluster
data "azurerm_lb" "kube_apiserver" {
  name                = "kube-apiserver"
  resource_group_name = local.node_resource_group
  depends_on          = [azapi_resource.cluster]
}

resource "azurerm_private_link_service" "apiserver" {
  name                                        = "pls-${local.cluster_name}-apiserver"
  location                                    = var.location
  resource_group_name                         = azurerm_resource_group.cell.name
  load_balancer_frontend_ip_configuration_ids = [data.azurerm_lb.kube_apiserver.frontend_ip_configuration[0].id]
  visibility_subscription_ids                 = [var.platform_subscription_ids["management"]]
  auto_approval_subscription_ids              = [var.platform_subscription_ids["management"]]
  tags                                        = local.tags

  nat_ip_configuration {
    name      = "primary"
    subnet_id = azurerm_subnet.this["apiserver-pls"].id
    primary   = true
  }
}

resource "azurerm_private_endpoint" "apiserver" {
  provider            = azurerm.management
  name                = "pe-${local.cluster_name}-apiserver"
  location            = var.location
  resource_group_name = data.azurerm_resource_group.api_access.name
  subnet_id           = data.azurerm_subnet.management_api_pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "apiserver"
    private_connection_resource_id = azurerm_private_link_service.apiserver.id
    is_manual_connection           = false
  }
}

locals {
  # <label>.<zone>: one zone per cluster (the part after the first label is unique per cluster), so rebuilding a
  # cell never touches another cell's records
  api_fqdn_labels = split(".", local.cluster_private_fqdn)
  api_dns_zone    = join(".", slice(local.api_fqdn_labels, 1, length(local.api_fqdn_labels)))
  api_dns_record  = local.api_fqdn_labels[0]
}

resource "azurerm_private_dns_zone" "apiserver" {
  provider            = azurerm.management
  name                = local.api_dns_zone
  resource_group_name = data.azurerm_resource_group.api_access.name
  tags                = local.tags
}

resource "azurerm_private_dns_a_record" "apiserver" {
  provider            = azurerm.management
  name                = local.api_dns_record
  zone_name           = azurerm_private_dns_zone.apiserver.name
  resource_group_name = data.azurerm_resource_group.api_access.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.apiserver.private_service_connection[0].private_ip_address]
}

# The management VNet resolves through the Firewall DNS proxy, i.e. in the hub's context: the zone is linked to
# the hub (where the query is answered) and to the management VNet. Other networks resolve the name too, but
# the private endpoint is reachable only from inside the management VNet (NSG on snet-aks-api-pe).
resource "azurerm_private_dns_zone_virtual_network_link" "apiserver" {
  provider = azurerm.management
  for_each = {
    hub        = local.hub_vnet.id
    management = data.azurerm_virtual_network.management.id
  }
  name                  = "link-${each.key}"
  resource_group_name   = data.azurerm_resource_group.api_access.name
  private_dns_zone_name = azurerm_private_dns_zone.apiserver.name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = local.tags
}
