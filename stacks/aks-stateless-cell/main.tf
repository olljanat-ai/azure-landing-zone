module "platform" {
  source       = "../../modules/platform-lookup"
  location     = var.location
  network_mode = var.network_mode
  providers = {
    azurerm.connectivity = azurerm.connectivity
    azurerm.management   = azurerm.management
  }
}

module "address_plan" {
  source      = "../../modules/address-plan"
  environment = var.environment
  countries   = var.countries
}

data "azurerm_client_config" "current" {}

# Shared resources of the environment (stacks/aks-environment), looked up by name
data "azurerm_key_vault" "platform" {
  name                = "kv-${var.environment}-platform-${var.name_suffix}"
  resource_group_name = "rg-aks-${var.environment}-shared-${var.location}"
}

data "azurerm_key_vault" "zone" {
  for_each            = module.address_plan.zones
  name                = "kv-${var.environment}-${each.key}-${var.name_suffix}"
  resource_group_name = "rg-aks-${var.environment}-shared-${var.location}"
}

# The environment's container registry is not part of the landing zone: onek8s/aks-terraform creates it (shared/)
data "azurerm_container_registry" "environment" {
  name                = var.container_registry.name
  resource_group_name = var.container_registry.resource_group_name
}

# Every identity of the environment that is used from a cluster carries the namespace and ServiceAccount it is
# federated to as tags (set by stacks/aks-environment); the cell adds one federated credential per identity.
data "azurerm_resources" "workload_identities" {
  type                = "Microsoft.ManagedIdentity/userAssignedIdentities"
  resource_group_name = "rg-aks-${var.environment}-identities-${var.location}"
}

data "azurerm_subnet" "management_api_pe" {
  provider             = azurerm.management
  name                 = "snet-aks-api-pe"
  virtual_network_name = "vnet-mgmt-${var.location}"
  resource_group_name  = "rg-mgmt-network-${var.location}"
}

data "azurerm_virtual_network" "management" {
  provider            = azurerm.management
  name                = "vnet-mgmt-${var.location}"
  resource_group_name = "rg-mgmt-network-${var.location}"
}

data "azurerm_resource_group" "api_access" {
  provider = azurerm.management
  name     = "rg-aks-${var.environment}-api-access-${var.location}"
}

# Version of the cell's speed (aks-design section 12, update policy): N-1 for sl-az1, N-2 for the others
data "azurerm_kubernetes_service_versions" "this" {
  location        = var.location
  include_preview = false
}

locals {
  env          = var.environment
  cell         = var.cell
  az           = substr(var.cell, 5, 1)
  cluster_name = "aks-${local.env}-${local.cell}"
  plan         = module.address_plan.cells[local.cell]
  zones        = module.address_plan.zones
  firewall     = module.platform.firewall_enabled
  firewall_ip  = module.platform.firewall_private_ip
  hub_vnet     = module.platform.hub_virtual_network

  tags = merge({
    deployed_by = "terraform"
    platform    = "aks"
    environment = var.environment
    cell        = var.cell
  }, var.tags)

  minors = sort(distinct([
    for v in data.azurerm_kubernetes_service_versions.this.versions : format("%03d", tonumber(split(".", v)[1]))
  ]))
  target_minor_full = "1.${tonumber(local.minors[length(local.minors) - 1 - var.kubernetes_minor_offset])}"
  target_patches = sort([
    for v in data.azurerm_kubernetes_service_versions.this.versions :
    format("%04d", tonumber(split(".", v)[2])) if join(".", slice(split(".", v), 0, 2)) == local.target_minor_full
  ])
  computed_version   = "${local.target_minor_full}.${tonumber(local.target_patches[length(local.target_patches) - 1])}"
  kubernetes_version = coalesce(var.kubernetes_version, local.computed_version)

  workload_identities = {
    for i, id in data.azurerm_resources.workload_identities.resources : id.name => {
      id              = id.id
      namespace       = id.tags["namespace"]
      service_account = id.tags["service_account"]
    } if can(id.tags["namespace"]) && can(id.tags["service_account"])
  }
}

resource "azurerm_resource_group" "cell" {
  name     = "rg-${local.cluster_name}-${var.location}"
  location = var.location
  tags     = local.tags
}
