output "hub_virtual_network" {
  description = "id, name and resource_group_name of the hub VNet."
  value = {
    id                  = data.azurerm_virtual_network.hub.id
    name                = data.azurerm_virtual_network.hub.name
    resource_group_name = data.azurerm_virtual_network.hub.resource_group_name
    address_space       = data.azurerm_virtual_network.hub.address_space
  }
}

output "firewall_private_ip" {
  description = "Private IP of the hub Azure Firewall: next hop of every spoke route table and DNS server (DNS proxy) of every spoke."
  value       = data.azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "firewall_policy_id" {
  description = "Resource ID of the hub firewall policy."
  value       = data.azurerm_firewall_policy.hub.id
}

output "dns_resolver_inbound_ip" {
  description = "Inbound endpoint IP of the hub Private DNS Resolver (what the corporate DNS forwards to)."
  value       = data.azurerm_private_dns_resolver_inbound_endpoint.hub.ip_configurations[0].private_ip_address
}

output "private_dns_zone_ids" {
  description = "Hub private DNS zones, key => resource ID."
  value       = { for k, v in data.azurerm_private_dns_zone.hub : k => v.id }
}

output "dns_resource_group_id" {
  description = "Resource group of the hub private DNS zones."
  value       = "${data.azurerm_subscription.connectivity.id}/resourceGroups/${local.dns_resource_group_name}"
}

output "log_analytics_workspace_id" {
  description = "Central Log Analytics workspace of the management subscription."
  value       = data.azurerm_log_analytics_workspace.management.id
}

output "connectivity_subscription_id" {
  description = "Subscription ID of sub-hub."
  value       = data.azurerm_subscription.connectivity.subscription_id
}
