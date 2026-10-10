# F5 NGINXaaS: internal entry point (cell router) of each int-* zone in the edge VNet (aks-design section 8),
# with client-IP affinity to the cells (`hash $client_prefix consistent`). The NGINX configuration with the cells'
# Traefik addresses as upstream servers is added once the cells exist. Optional until the open question about
# the partner service is answered.
resource "azurerm_nginx_deployment" "zone" {
  for_each                  = var.nginxaas_enabled ? local.edge.zones : {}
  name                      = "nginx-${local.env}-${each.key}"
  resource_group_name       = azurerm_resource_group.shared.name
  location                  = var.location
  sku                       = "standardv3_Monthly"
  automatic_upgrade_channel = "stable"
  capacity                  = 10
  tags                      = merge(local.tags, { zone = each.key })

  frontend_private {
    ip_address        = cidrhost(each.value.snet_nginx, 4)
    allocation_method = "Static"
    subnet_id         = azurerm_subnet.edge[each.key].id
  }

  network_interface {
    subnet_id = azurerm_subnet.edge[each.key].id
  }
}
