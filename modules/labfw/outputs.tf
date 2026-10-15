output "private_ip" {
  description = "Next hop of the spoke route tables (and their DNS server with the DNS proxy)."
  value       = local.private_ip
}

output "public_ip" {
  description = "Internet egress (SNAT) and VPN endpoint address."
  value       = azurerm_public_ip.labfw.ip_address
}

output "vpn_endpoint" {
  description = "WireGuard endpoint host:port, null without the VPN."
  value       = var.vpn.enabled ? "${azurerm_public_ip.labfw.ip_address}:${var.vpn.listen_port}" : null
}

output "vpn_pool" {
  description = "Address pool of the VPN clients, null without the VPN."
  value       = local.vpn_pool
}

output "resource_group_name" {
  value = azurerm_resource_group.labfw.name
}

output "virtual_machine_id" {
  value = azurerm_linux_virtual_machine.labfw.id
}

output "identity_principal_id" {
  value = azurerm_user_assigned_identity.labfw.principal_id
}

output "dns_clients" {
  description = "Prefixes labfw's DNS proxy answers and its NSG lets in: the trusted prefixes (hub and spokes) and the VPN pool."
  value       = local.dns_clients
}

output "log_analytics_workspace" {
  description = "The workspace of labfw's connection log (table LabfwFirewallLog_CL): resource ID and customer (workspace) ID; null without log_analytics."
  value       = local.log_analytics ? { id = azurerm_log_analytics_workspace.labfw[0].id, workspace_id = azurerm_log_analytics_workspace.labfw[0].workspace_id, table = azurerm_log_analytics_workspace_table_custom_log.labfw[0].name } : null
}
