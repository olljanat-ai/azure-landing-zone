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
