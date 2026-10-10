# Azure Policy for the AKS platform (aks-design section 14), assigned to the environment subscription so that a
# new or rebuilt cluster gets every policy automatically. Built-in definitions first; the platform's custom
# Microsoft.Kubernetes.Data definitions (zone pinning, FQDN egress, ESO-only secrets, Gateway API only, ...) are
# added here in phase 2 and tested with `gator verify`.
#
# Build tenant: every assignment uses var.policy_enforcement_mode (DoNotEnforce = audit only, section 17).
locals {
  enforce = var.policy_enforcement_mode == "Default"

  policy_assignments = {
    # Kubernetes (Azure Policy add-on / Gatekeeper)
    k8s-pod-security-restricted = {
      id          = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
      description = "Kubernetes pod security restricted standards for Linux workloads"
      parameters = {
        effect             = { value = local.enforce ? "Deny" : "Audit" }
        excludedNamespaces = { value = ["kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system", "flux-system", "kube-public", "aks-istio-system"] }
      }
    }
    k8s-allowed-images = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/febd0533-8e55-448f-b837-bd0e06f16469"
      description = "Images only from the environment's ACR"
      parameters = {
        effect                      = { value = local.enforce ? "Deny" : "Audit" }
        allowedContainerImagesRegex = { value = "^${azurerm_container_registry.this.login_server}/.+$" }
        excludedNamespaces          = { value = ["kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system", "flux-system"] }
      }
    }
    # Cluster resources
    aks-azure-policy-add-on = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/0a15ec92-a229-4763-bb14-0ea34a568f8d"
      description = "Azure Policy add-on installed on every cluster"
      parameters  = { effect = { value = "Audit" } }
    }
    aks-private-cluster = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/040732e8-d947-40b8-95d6-854c95024bf8"
      description = "Private API server"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-local-accounts-disabled = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9eb0-df2c3a730c32"
      description = "Entra ID only, no local accounts"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-encryption-at-host = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/41425d9f-d1a5-499a-9932-f8ed8453932c"
      description = "Encryption at host on every node (section 18)"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-cmk-disks = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/7d7be79c-23ba-4033-84dd-45e2a5ccdd67"
      description = "OS and data disks with customer-managed keys (section 18)"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    # Key Vault and ACR
    key-vault-purge-protection = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/0b60c0b2-2dc2-4e1c-b5c9-abbed971de53"
      description = "Purge protection on every vault"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    key-vault-no-public-access = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/405c5871-3e91-4644-8a63-58e19d68ff5b"
      description = "No public network access to Key Vault"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    acr-admin-disabled = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/dc921057-6b28-4fbe-9b83-f7bec05db6c2"
      description = "No ACR admin user"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
  }
}

resource "azurerm_subscription_policy_assignment" "aks" {
  for_each             = local.policy_assignments
  name                 = "aks-${local.env}-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.description}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = each.value.id
  enforce              = local.enforce
  parameters           = jsonencode(each.value.parameters)
  location             = var.location

  non_compliance_message {
    content = "Violates the AKS platform design (aks-design section 14): ${each.value.description}."
  }
}
