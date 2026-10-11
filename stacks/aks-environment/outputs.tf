output "address_plan" {
  description = "Prefixes of the environment."
  value = {
    environment = module.address_plan.environment_prefix
    zones       = { for z, v in local.zones : z => { frontend = v.frontend, backend = v.backend } }
  }
}

output "key_vaults" {
  description = "Zone and platform Key Vaults: name and URI."
  value       = { for k, v in azurerm_key_vault.this : k => { id = v.id, name = v.name, uri = v.vault_uri } }
}

output "gateway_secret_reader_client_ids" {
  description = "Client IDs of id-<zone>-gateway-secrets (annotation of the secrets-reader ServiceAccount in <zone>-gateway)."
  value       = { for k, v in azurerm_user_assigned_identity.gateway_secrets : k => v.client_id }
}

output "application_identities" {
  description = "Client IDs of the onboarded applications' workload and secret reader identities."
  value = { for k, v in var.applications : k => {
    workload       = azurerm_user_assigned_identity.application[k].client_id
    secrets_reader = try(azurerm_user_assigned_identity.application_secrets[k].client_id, null)
  } }
}

output "front_door_endpoints" {
  description = "Front Door endpoint host names of the external zones."
  value       = { for k, v in azurerm_cdn_frontdoor_endpoint.zone : k => v.host_name }
}
