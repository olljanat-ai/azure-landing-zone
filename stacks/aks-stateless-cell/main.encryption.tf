# Customer-managed keys (aks-design section 18), created by the cell module before the cluster: a cluster
# created without them would have to be rebuilt.
#   key-<cell>-kms   KMS etcd encryption, used by the control plane identity (Key Vault Crypto User on the key)
#   key-<cell>-disk  disk encryption set des-<env>-<cell> for the OS disks of all nodes (system pool + NAP)
# No expiry date on any key version; the rotation policy only creates new versions.
resource "azurerm_key_vault_key" "cluster" {
  for_each     = toset(["kms", "disk"])
  name         = "key-${local.cell}-${each.key}"
  key_vault_id = data.azurerm_key_vault.platform.id
  key_type     = "RSA-HSM"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]
  tags         = merge(local.tags, { purpose = each.key })

  rotation_policy {
    automatic {
      time_after_creation = "P1Y"
    }
  }
}

resource "azurerm_disk_encryption_set" "cluster" {
  name                      = "des-${local.env}-${local.cell}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.cell.name
  key_vault_key_id          = azurerm_key_vault_key.cluster["disk"].versionless_id
  auto_key_rotation_enabled = true
  encryption_type           = "EncryptionAtRestWithCustomerKey"
  tags                      = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "des_key" {
  scope                = azurerm_key_vault_key.cluster["disk"].resource_versionless_id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.cluster.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Control plane identity (KMS requires a user-assigned one) and kubelet identity
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-aks-${local.env}-${local.cell}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "id-aks-${local.env}-${local.cell}-kubelet"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  tags                = local.tags
}

locals {
  control_plane_roles = {
    # VNet, subnets, route tables and NSGs of the cell (NAP creates NICs in the zone subnets)
    network = { scope = azurerm_resource_group.cell.id, role = "Network Contributor" }
    kubelet = { scope = azurerm_user_assigned_identity.kubelet.id, role = "Managed Identity Operator" }
    kms_key = { scope = azurerm_key_vault_key.cluster["kms"].resource_versionless_id, role = "Key Vault Crypto User" }
    # Management plane only: AKS creates the private endpoint of the private vault for KMS (trade-off, section 18)
    kms_vault = { scope = data.azurerm_key_vault.platform.id, role = "Key Vault Contributor" }
    des       = { scope = azurerm_disk_encryption_set.cluster.id, role = "Reader" }
  }
}

resource "azurerm_role_assignment" "control_plane" {
  for_each             = local.control_plane_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
}

# Images are pulled with the kubelet identity: AcrPull on the environment's ACR only, no imagePullSecrets.
# The kubelet identity is never granted access to a Key Vault (section 4).
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = data.azurerm_container_registry.environment.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
  principal_type       = "ServicePrincipal"
}

# Role assignments take a while to propagate; KMS and the disk encryption set are checked when the cluster is created
resource "time_sleep" "rbac_propagation" {
  create_duration = "120s"
  depends_on = [
    azurerm_role_assignment.control_plane,
    azurerm_role_assignment.des_key,
    azurerm_role_assignment.kubelet_acr_pull,
  ]
}
