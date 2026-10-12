output "hub_virtual_network" {
  description = "id, name and resource_group_name of the hub VNet."
  value = {
    id                  = data.azurerm_virtual_network.hub.id
    name                = data.azurerm_virtual_network.hub.name
    resource_group_name = data.azurerm_virtual_network.hub.resource_group_name
    address_space       = data.azurerm_virtual_network.hub.address_space
  }
}

output "firewall_enabled" {
  description = "true in network mode firewall."
  value       = var.network_mode == "firewall"
}

output "firewall_private_ip" {
  description = "Private IP of the hub Azure Firewall: next hop of every spoke route table (null in sandbox mode)."
  value       = one(data.azurerm_firewall.hub[*].ip_configuration[0].private_ip_address)
}

output "firewall_policy_id" {
  description = "Resource ID of the hub firewall policy (null in sandbox mode)."
  value       = one(data.azurerm_firewall_policy.hub[*].id)
}

output "dns_server_ip" {
  description = "Custom DNS server of every spoke: the Firewall DNS proxy in firewall mode; null in sandbox mode (Azure DNS with the hub zones linked to the spoke, see private_dns_zones)."
  value       = one(data.azurerm_firewall.hub[*].ip_configuration[0].private_ip_address)
}

output "dns_servers" {
  description = "dns_servers of every spoke VNet: [Firewall DNS proxy] in firewall mode, [] (Azure DNS) in sandbox mode."
  value       = data.azurerm_firewall.hub[*].ip_configuration[0].private_ip_address
}

output "private_dns_zones" {
  description = "Every private link zone of the hub (privatelink.*), name => resource ID. Sandbox mode links each spoke VNet to all of them."
  value       = { for z in data.azurerm_resources.private_dns_zones.resources : z.name => z.id if startswith(z.name, "privatelink.") }
}

output "dns_resource_group_name" {
  description = "Resource group of the hub private DNS zones."
  value       = local.dns_resource_group_name
}

output "private_dns_zone_ids" {
  description = "Hub private DNS zones, key => resource ID."
  value       = { for k, v in data.azurerm_private_dns_zone.hub : k => v.id }
}

output "dns_resource_group_id" {
  description = "Resource group of the hub private DNS zones."
  value       = "${data.azurerm_subscription.connectivity.id}/resourceGroups/${local.dns_resource_group_name}"
}

output "connectivity_subscription_id" {
  description = "Subscription ID of sub-hub."
  value       = data.azurerm_subscription.connectivity.subscription_id
}
