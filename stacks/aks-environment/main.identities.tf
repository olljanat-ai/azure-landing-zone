# Identities that must survive a cluster rebuild (OneK8s design sections 6 and 13). Federated credentials are per
# cluster (own OIDC issuer) and are added by the cell stack.
#
# - id-<zone>-gateway-secrets: secret reader of the zone's Traefik namespace <zone>-gateway, used only by the
#   zone's External Secrets Operator; Key Vault Secrets User on the zone certificate in the platform vault only.
# - id-<zone>-<app>: workload identity of an onboarded application, no Key Vault role at all.
# - id-<zone>-<app>-secrets: secret reader of an application with a secret exception (ABAC: own prefix only)
#   and / or a certificate.
resource "azurerm_user_assigned_identity" "gateway_secrets" {
  for_each            = local.zones
  name                = "id-${each.key}-gateway-secrets"
  location            = var.location
  resource_group_name = azurerm_resource_group.identities.name
  tags                = merge(local.tags, { zone = each.key, namespace = "${each.key}-gateway", service_account = "secrets-reader" })
}

resource "azurerm_role_assignment" "gateway_certificate" {
  for_each             = local.zones
  scope                = "${azurerm_key_vault.this["platform"].id}/secrets/${azurerm_key_vault_certificate.zone_wildcard[each.key].name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.gateway_secrets[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_user_assigned_identity" "application" {
  for_each            = var.applications
  name                = "id-${each.value.zone}-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.identities.name
  tags                = merge(local.tags, { zone = each.value.zone, namespace = "${each.value.zone}-${each.key}", service_account = each.key })
}

resource "azurerm_user_assigned_identity" "application_secrets" {
  for_each            = { for k, v in var.applications : k => v if v.needs_secrets || v.needs_certificate }
  name                = "id-${each.value.zone}-${each.key}-secrets"
  location            = var.location
  resource_group_name = azurerm_resource_group.identities.name
  tags                = merge(local.tags, { zone = each.value.zone, namespace = "${each.value.zone}-${each.key}", service_account = "secrets-reader" })
}

# Key Vault RBAC + ABAC (R7): the reader may get only secrets whose name starts with "<app>-"
resource "azurerm_role_assignment" "application_secrets_reader" {
  for_each             = { for k, v in var.applications : k => v if v.needs_secrets }
  scope                = azurerm_key_vault.this[each.value.zone].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.application_secrets[each.key].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = <<-CONDITION
    (
     (
      !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/getSecret/action'})
     )
     OR
     (
      @Resource[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${each.key}-'
     )
    )
  CONDITION
}

# Application pipelines: Secrets Officer limited to the application's own prefix when setting secrets
resource "azurerm_role_assignment" "application_secrets_officer" {
  for_each = merge([for app, v in var.applications : {
    for id in v.secret_officer_ids : "${app}-${id}" => { app = app, zone = v.zone, principal_id = id }
  } if v.needs_secrets]...)
  scope                = azurerm_key_vault.this[each.value.zone].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value.principal_id
  condition_version    = "2.0"
  condition            = <<-CONDITION
    (
     (
      !(ActionMatches{'Microsoft.KeyVault/vaults/secrets/setSecret/action'})
     )
     OR
     (
      @Request[Microsoft.KeyVault/vaults/secrets:name] StringStartsWith '${each.value.app}-'
     )
    )
  CONDITION
}

resource "azurerm_role_assignment" "application_certificate" {
  for_each             = { for k, v in var.applications : k => v if v.needs_certificate }
  scope                = "${azurerm_key_vault.this["platform"].id}/secrets/${azurerm_key_vault_certificate.zone_wildcard[each.value.zone].name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.application_secrets[each.key].principal_id
  principal_type       = "ServicePrincipal"
}
