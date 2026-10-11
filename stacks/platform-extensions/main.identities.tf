# Deployment identities of the AKS environments (OneK8s design sections 9, 10 and 17): one plan (read) and one
# apply (write) identity per environment, federated with this repository's GitHub environments
# `aks-<env>-plan` and `aks-<env>-apply`. Like the accelerator's own identities they live in sub-mgmt, so a
# rebuilt environment subscription keeps its deployment path.
data "azurerm_storage_account" "state" {
  name                = var.state_storage_account_name
  resource_group_name = var.state_resource_group_name
}

data "azurerm_subscription" "environment" {
  for_each        = var.environments
  subscription_id = each.value.subscription_id
}

data "azurerm_subscription" "management" {}

resource "azurerm_resource_group" "aks_identities" {
  name     = "rg-aks-identities-${var.location}"
  location = var.location
  tags     = var.tags
}

# Private endpoints to the API servers of an environment's clusters and their DNS records (created by the
# cell stack) live here, in sub-mgmt, next to the management VNet.
resource "azurerm_resource_group" "aks_api_access" {
  for_each = var.environments
  name     = "rg-aks-${each.key}-api-access-${var.location}"
  location = var.location
  tags     = var.tags
}

locals {
  identity_roles = {
    plan  = "plan"
    apply = "apply"
  }
  environment_identities = merge([for env, _ in var.environments : {
    for role, _ in local.identity_roles : "${env}-${role}" => { env = env, role = role }
  }]...)
}

resource "azurerm_user_assigned_identity" "aks" {
  for_each            = local.environment_identities
  name                = "id-aks-${each.value.env}-${each.value.role}-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.aks_identities.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "aks" {
  for_each  = local.environment_identities
  name      = "github-${replace(var.github_repository, "/", "-")}-aks-${each.key}"
  parent_id = azurerm_user_assigned_identity.aks[each.key].id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "${var.github_oidc_subject_prefix}:environment:aks-${each.key}"
}

# The apply identity of an environment also deploys from the environment's other repositories - aks-terraform:
# the clusters, the container registry, the certificates - from their own GitHub environment.
locals {
  deployment_repositories = merge([for env, cfg in var.environments : {
    for repo, r in cfg.deployment_repositories : "${env}-${repo}" => merge(r, { env = env, repo = repo })
  }]...)
}

resource "azurerm_federated_identity_credential" "deployment_repositories" {
  for_each  = local.deployment_repositories
  name      = "github-${each.value.repo}-${each.value.github_environment}"
  parent_id = azurerm_user_assigned_identity.aks["${each.value.env}-apply"].id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "${each.value.subject_prefix}:environment:${each.value.github_environment}"
}

# Custom role on a VNet: peer AKS spokes to it and link private DNS zones to it, nothing else. Assigned on the hub
# VNet in both network modes; in sandbox mode also on the management VNet (management <-> backend spoke) and the
# client VNet (client <-> edge VNet), because there is no Firewall to route between them.
locals {
  spoke_peering_actions = [
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/peer/action",
    "Microsoft.Network/virtualNetworks/join/action",
    "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/read",
    "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write",
    "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/delete",
  ]
}

resource "azurerm_role_definition" "hub_spoke_peering" {
  provider    = azurerm.connectivity
  name        = "AKS spoke peering (${var.location})"
  scope       = local.hub_vnet.id
  description = "Create and delete VNet peerings and private DNS zone links on the hub and client VNets for AKS spokes."
  permissions {
    actions = local.spoke_peering_actions
  }
  assignable_scopes = [local.hub_vnet.id, azurerm_virtual_network.client.id]
}

resource "azurerm_role_definition" "management_spoke_peering" {
  name        = "AKS spoke peering to management (${var.location})"
  scope       = azurerm_virtual_network.management.id
  description = "Create and delete VNet peerings between the management VNet and AKS backend spokes (sandbox network mode)."
  permissions {
    actions = local.spoke_peering_actions
  }
  assignable_scopes = [azurerm_virtual_network.management.id]
}

locals {
  role_assignments = merge([for env, cfg in var.environments : {
    # plan
    "${env}-plan-env-reader"     = { identity = "${env}-plan", scope = data.azurerm_subscription.environment[env].id, role = "Reader" }
    "${env}-plan-env-kv-reader"  = { identity = "${env}-plan", scope = data.azurerm_subscription.environment[env].id, role = "Key Vault Reader" }
    "${env}-plan-env-aks-reader" = { identity = "${env}-plan", scope = data.azurerm_subscription.environment[env].id, role = "Azure Kubernetes Service RBAC Reader" }
    "${env}-plan-hub-reader"     = { identity = "${env}-plan", scope = "/subscriptions/${var.subscription_ids["connectivity"]}", role = "Reader" }
    "${env}-plan-mgmt-reader"    = { identity = "${env}-plan", scope = data.azurerm_subscription.management.id, role = "Reader" }
    "${env}-plan-state"          = { identity = "${env}-plan", scope = "${data.azurerm_storage_account.state.id}/blobServices/default/containers/${var.state_container_name}", role = "Storage Blob Data Contributor" }
    # apply: Owner of the environment subscription (role assignments for cluster, workload and ESO identities)
    "${env}-apply-env-owner"       = { identity = "${env}-apply", scope = data.azurerm_subscription.environment[env].id, role = "Owner" }
    "${env}-apply-env-kv-admin"    = { identity = "${env}-apply", scope = data.azurerm_subscription.environment[env].id, role = "Key Vault Administrator" }
    "${env}-apply-env-aks-admin"   = { identity = "${env}-apply", scope = data.azurerm_subscription.environment[env].id, role = "Azure Kubernetes Service RBAC Cluster Admin" }
    "${env}-apply-hub-reader"      = { identity = "${env}-apply", scope = "/subscriptions/${var.subscription_ids["connectivity"]}", role = "Reader" }
    "${env}-apply-hub-dns"         = { identity = "${env}-apply", scope = module.platform.dns_resource_group_id, role = "Private DNS Zone Contributor" }
    "${env}-apply-mgmt-reader"     = { identity = "${env}-apply", scope = data.azurerm_subscription.management.id, role = "Reader" }
    "${env}-apply-api-access"      = { identity = "${env}-apply", scope = azurerm_resource_group.aks_api_access[env].id, role = "Contributor" }
    "${env}-apply-api-access-snet" = { identity = "${env}-apply", scope = azurerm_subnet.management_aks_api_pe.id, role = "Network Contributor" }
    "${env}-apply-state"           = { identity = "${env}-apply", scope = "${data.azurerm_storage_account.state.id}/blobServices/default/containers/${var.state_container_name}", role = "Storage Blob Data Contributor" }
  }]...)
}

resource "azurerm_role_assignment" "aks" {
  for_each             = local.role_assignments
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.aks[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aks_hub_peering" {
  provider           = azurerm.connectivity
  for_each           = var.environments
  scope              = local.hub_vnet.id
  role_definition_id = azurerm_role_definition.hub_spoke_peering.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.aks["${each.key}-apply"].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aks_client_peering" {
  provider           = azurerm.connectivity
  for_each           = local.firewall ? {} : var.environments
  scope              = azurerm_virtual_network.client.id
  role_definition_id = azurerm_role_definition.hub_spoke_peering.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.aks["${each.key}-apply"].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "aks_management_peering" {
  for_each           = local.firewall ? {} : var.environments
  scope              = azurerm_virtual_network.management.id
  role_definition_id = azurerm_role_definition.management_spoke_peering.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.aks["${each.key}-apply"].principal_id
  principal_type     = "ServicePrincipal"
}
