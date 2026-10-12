# Plans the stack with a mocked provider (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}

variables {
  environment             = "dev"
  location                = "swedencentral"
  subscription_id         = "00000000-0000-0000-0000-000000000003"
  container_registry_name = "acronek8sdev"
}

run "audit_in_the_build_tenant" {
  command = plan

  assert {
    condition     = alltrue([for a in azurerm_subscription_policy_assignment.aks : !a.enforce])
    error_message = "DoNotEnforce: no assignment may enforce."
  }
}

run "new_definitions_stay_audit_when_enforced" {
  command = plan

  variables {
    policy_enforcement_mode = "Default"
  }

  assert {
    condition = alltrue([
      for k in ["k8s-deployment-safeguards", "k8s-read-only-root-filesystem", "k8s-no-service-account-token-automount", "k8s-no-ingress", "k8s-internal-load-balancers", "k8s-image-integrity", "aks-ssh-disabled", "aks-azure-cni", "aks-workload-identity"] :
      jsondecode(azurerm_subscription_policy_assignment.aks[k].parameters).effect.value == "Audit"
    ])
    error_message = "Definitions not yet promoted keep effect Audit."
  }

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.aks["k8s-allowed-images"].parameters).allowedContainerImagesRegex.value == "^acronek8sdev\\.azurecr\\.io/[^@]+@sha256:[a-f0-9]{64}$"
    error_message = "Images by digest from the environment's registry only."
  }
}
