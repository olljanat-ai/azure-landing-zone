# Plans the stack with a mocked provider (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}

variables {
  environment                 = "dev"
  location                    = "swedencentral"
  subscription_id             = "00000000-0000-0000-0000-000000000003"
  container_registry_name     = "acronek8sdev"
  zone_domain_suffix          = "dev.onek8s.lol"
  cluster_resource_group_name = "rg-aks-dev"
  stateless_cluster_names     = ["aks-dev-stateless-az1", "aks-dev-stateless-az2"]
  stateful_cluster_name       = "aks-dev-stateful"
}

run "audit_in_the_build_tenant" {
  command = plan

  assert {
    condition     = alltrue([for a in azurerm_subscription_policy_assignment.aks : !a.enforce])
    error_message = "DoNotEnforce: no built-in assignment may enforce."
  }

  assert {
    condition = alltrue([
      for k, a in azurerm_subscription_policy_assignment.kubernetes :
      a.enforce == contains(["no-persistent-storage", "portable-storage-only"], k)
    ])
    error_message = "DoNotEnforce: of the platform's validations only the storage rules, which replaced enforced ValidatingAdmissionPolicies, enforce."
  }

  assert {
    condition = alltrue([
      for k, a in azurerm_subscription_policy_assignment.kubernetes :
      jsondecode(a.parameters).effect.value == (contains(["no-persistent-storage", "portable-storage-only"], k) ? "Deny" : "Audit")
    ])
    error_message = "The storage rules deny; every other platform validation audits."
  }
}

run "platform_kubernetes_policies" {
  command = plan

  assert {
    condition     = length(azurerm_policy_definition.kubernetes) == 7 && alltrue([for d in azurerm_policy_definition.kubernetes : d.mode == "Microsoft.Kubernetes.Data"])
    error_message = "One Microsoft.Kubernetes.Data definition per constraint template."
  }

  assert {
    condition = alltrue([
      for k, d in azurerm_policy_definition.kubernetes :
      base64decode(jsondecode(d.policy_rule).then.details.templateInfo.content) == file("kubernetes/templates/${k}.yaml")
    ])
    error_message = "Each definition embeds its template from kubernetes/templates unchanged."
  }

  assert {
    condition     = length(azurerm_policy_definition.kubernetes_mutation) == 12 && alltrue([for a in azurerm_subscription_policy_assignment.kubernetes_mutation : a.enforce && jsondecode(a.parameters).effect.value == "Mutate"])
    error_message = "Two mutations per zone and four for architecture and spot, all enforced."
  }

  assert {
    condition     = strcontains(base64decode(jsondecode(azurerm_policy_definition.kubernetes_mutation["zone-node-selector-int-se"].policy_rule).then.details.mutationInfo.content), "value: \"int-se\"")
    error_message = "The zone mutations are rendered per zone."
  }

  assert {
    condition = (
      azurerm_subscription_policy_assignment.kubernetes["no-persistent-storage"].not_scopes == tolist(["/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev/providers/Microsoft.ContainerService/managedClusters/aks-dev-stateful"]) &&
      length(azurerm_subscription_policy_assignment.kubernetes["portable-storage-only"].not_scopes) == 2 &&
      endswith(azurerm_subscription_policy_assignment.kubernetes["portable-storage-only"].not_scopes[0], "/managedClusters/aks-dev-stateless-az1") &&
      length(coalesce(azurerm_subscription_policy_assignment.kubernetes["zone-placement"].not_scopes, [])) == 0
    )
    error_message = "Stateless rules leave out the stateful cluster, stateful rules the stateless cells, zone rules reach every cluster."
  }

  assert {
    condition     = alltrue([for d in azurerm_policy_definition.kubernetes : jsondecode(d.policy_rule).if.field == "type"])
    error_message = "A Kubernetes definition's rule may test only type, location and tags."
  }

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.kubernetes["gateway-only"].parameters).domainSuffix.value == "dev.onek8s.lol"
    error_message = "Routes are held to the environment's zone domains."
  }

  assert {
    condition = alltrue([
      for k in ["zone-placement", "placement-labels", "fqdn-egress", "gateway-only", "portable-storage-only"] :
      contains(jsondecode(azurerm_subscription_policy_assignment.kubernetes[k].parameters).excludedNamespaces.value, "*-gateway")
    ])
    error_message = "The application rules leave out the platform's namespaces, the zones' gateways and secrets included."
  }
}

run "new_definitions_stay_audit_when_enforced" {
  command = plan

  variables {
    policy_enforcement_mode = "Default"
  }

  assert {
    condition     = alltrue([for k in ["zone-placement", "placement-labels", "fqdn-egress", "gateway-only", "node-pools"] : jsondecode(azurerm_subscription_policy_assignment.kubernetes[k].parameters).effect.value == "Audit"])
    error_message = "The platform's new validations keep effect Audit until promoted."
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
