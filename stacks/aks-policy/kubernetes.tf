# The platform's own Kubernetes policies (OneK8s design section 14): custom Microsoft.Kubernetes.Data
# definitions with the Gatekeeper constraint and mutation templates of kubernetes/ embedded as
# Base64, assigned to the environment subscription like the built-ins in main.tf. The Azure Policy
# add-on of every cluster pulls them in within 15 minutes. kubernetes/test.sh tests the templates
# (gator, also in CI).
#
# Which clusters a definition reaches goes by the cluster's name (clusterNamePattern, Azure Policy
# `like`): the stateless cells and the stateful cluster share the subscription.
#
# Effects:
#   - new validations start as Audit, also when policy_enforcement_mode is Default (section 14:
#     audit in dev first, then deny);
#   - the storage rules are enforced (Deny) in every mode: they replace the fleet's
#     ValidatingAdmissionPolicies, which already refused this, so moving them to the one policy
#     engine (R14) must not turn them into audit;
#   - the mutations are enforced in every mode: they only fill in what a pod leaves out and refuse
#     nothing, and R17's labels do not work without them.
locals {
  # Platform namespaces of the cluster and of aks-fluxcd-platform: left out of the application
  # rules. The zones' own `<zone>-gateway` and `<zone>-secrets` run on the system pool.
  kubernetes_excluded_namespaces = concat(local.platform_namespaces, [
    "kube-node-lease", "external-secrets", "external-dns", "platform-gateway", "*-gateway", "*-secrets",
  ])

  all_clusters = "*"

  # The constraint templates: what they match, and the types of their parameters.
  k8s_templates = {
    no-persistent-storage = { api_groups = ["", "storage.k8s.io"], kinds = ["Pod", "PersistentVolume", "PersistentVolumeClaim", "StorageClass"], parameters = {} }
    portable-storage-only = { api_groups = [""], kinds = ["Pod", "PersistentVolumeClaim"], parameters = { storageClassName = "String" } }
    zone-placement        = { api_groups = [""], kinds = ["Pod", "Namespace"], parameters = { zones = "Array" } }
    placement-labels      = { api_groups = [""], kinds = ["Pod"], parameters = { allowedArchitectures = "Array", allowedCapacities = "Array" } }
    fqdn-egress           = { api_groups = ["", "cilium.io", "networking.k8s.io"], kinds = ["Pod", "CiliumNetworkPolicy", "NetworkPolicy"], parameters = { sharedSuffixes = "Array" } }
    gateway-only          = { api_groups = ["", "gateway.networking.k8s.io"], kinds = ["Service", "Gateway", "HTTPRoute"], parameters = { zones = "Array", domainSuffix = "String" } }
    node-pools            = { api_groups = ["karpenter.sh", "karpenter.azure.com"], kinds = ["NodePool", "AKSNodeClass"], parameters = { zones = "Array", allowedSkuSeries = "Array", exemptNames = "Array" } }
  }

  k8s_validations = {
    no-persistent-storage = {
      display     = "Stateless clusters: no StorageClass, PersistentVolume, PersistentVolumeClaim, csi or ephemeral volume"
      template    = "no-persistent-storage"
      clusters    = var.stateless_cluster_name_pattern
      excluded    = ["kube-system"]
      values      = {}
      always_deny = true
    }
    portable-storage-only = {
      display     = "Clusters with storage: claims only on the portable StorageClass, no inline csi volumes"
      template    = "portable-storage-only"
      clusters    = var.stateful_cluster_name_pattern
      excluded    = local.kubernetes_excluded_namespaces
      values      = { storageClassName = "portable-disk" }
      always_deny = true
    }
    zone-placement = {
      display     = "Isolation zones: zone namespaces carry their label, their pods run on the zone's nodes only"
      template    = "zone-placement"
      clusters    = local.all_clusters
      excluded    = local.kubernetes_excluded_namespaces
      values      = { zones = var.isolation_zones }
      always_deny = false
    }
    placement-labels = {
      display     = "Stateless clusters: architecture and spot only through the platform/arch and platform/capacity labels"
      template    = "placement-labels"
      clusters    = var.stateless_cluster_name_pattern
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedArchitectures = ["amd64", "arm64", "multi"], allowedCapacities = ["on-demand", "spot"] }
      always_deny = false
    }
    placement-labels-stateful = {
      display     = "Stateful cluster: amd64 on-demand only"
      template    = "placement-labels"
      clusters    = var.stateful_cluster_name_pattern
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedArchitectures = ["amd64"], allowedCapacities = ["on-demand"] }
      always_deny = false
    }
    fqdn-egress = {
      display  = "Egress only by FQDN: Cilium policies without CIDRs, entities or broad wildcards; pods use the cluster DNS"
      template = "fqdn-egress"
      clusters = local.all_clusters
      excluded = local.kubernetes_excluded_namespaces
      values = {
        # Suffixes under which every customer has names (aks-fluxcd-platform scripts/check-egress.py)
        sharedSuffixes = [
          "core.windows.net", "blob.core.windows.net", "database.windows.net", "servicebus.windows.net",
          "azurewebsites.net", "cloudapp.azure.com", "cloudapp.net", "azurecr.io", "azure.com", "windows.net",
          "amazonaws.com", "googleapis.com", "github.io", "githubusercontent.com",
        ]
      }
      always_deny = false
    }
    gateway-only = {
      display     = "Stateless clusters: applications published only through their zone's HTTPS Gateway"
      template    = "gateway-only"
      clusters    = var.stateless_cluster_name_pattern
      excluded    = local.kubernetes_excluded_namespaces
      values      = { zones = var.isolation_zones, domainSuffix = var.zone_domain_suffix }
      always_deny = false
    }
    node-pools = {
      display  = "Stateless clusters: NAP NodePools and AKSNodeClasses per zone, in its subnet, with its label, taints and VM series"
      template = "node-pools"
      clusters = var.stateless_cluster_name_pattern
      excluded = []
      values = {
        zones            = var.isolation_zones
        allowedSkuSeries = var.allowed_sku_series
        # Created and managed by AKS itself
        exemptNames = ["default", "system-surge"]
      }
      always_deny = false
    }
  }

  # One definition per mutation (Azure cannot parameterize them): the zone ones per zone.
  k8s_mutations = merge(
    { for pair in setproduct(var.isolation_zones, ["zone-node-selector", "zone-toleration"]) :
      "${pair[1]}-${pair[0]}" => {
        display = "Zone ${pair[0]}: ${pair[1] == "zone-node-selector" ? "pods select the zone's nodes" : "pods tolerate the zone's taint"}"
        content = templatefile("${path.module}/kubernetes/mutations/${pair[1]}.yaml.tftpl", { zone = pair[0] })
      }
    },
    {
      arch-amd64      = { display = "platform/arch amd64 (default): nodeSelector kubernetes.io/arch amd64", content = file("${path.module}/kubernetes/mutations/arch-amd64.yaml.tftpl") }
      arch-arm64      = { display = "platform/arch arm64: nodeSelector kubernetes.io/arch arm64", content = file("${path.module}/kubernetes/mutations/arch-arm64.yaml.tftpl") }
      spot-toleration = { display = "platform/capacity spot: the spot taint tolerated", content = file("${path.module}/kubernetes/mutations/spot-toleration.yaml.tftpl") }
      spot-affinity   = { display = "platform/capacity spot: spot nodes preferred", content = file("${path.module}/kubernetes/mutations/spot-affinity.yaml.tftpl") }
    },
  )

  cluster_rule = {
    allOf = [
      { field = "type", in = ["Microsoft.ContainerService/managedClusters"] },
      { field = "name", like = "[parameters('clusterNamePattern')]" },
    ]
  }

  cluster_name_parameter = {
    clusterNamePattern = {
      type         = "String"
      defaultValue = "*"
      metadata     = { displayName = "Clusters", description = "Names of the clusters the definition applies to, an Azure Policy `like` pattern." }
    }
  }
}

resource "azurerm_policy_definition" "kubernetes" {
  # One definition per template; a template assigned twice (placement-labels) shares it.
  for_each = local.k8s_templates

  name         = "onek8s-k8s-${each.key}"
  display_name = "OneK8s: ${each.key}"
  description  = yamldecode(file("${path.module}/kubernetes/templates/${each.key}.yaml")).metadata.annotations.description
  policy_type  = "Custom"
  mode         = "Microsoft.Kubernetes.Data"
  metadata     = jsonencode({ category = "Kubernetes", version = "1.0.0", source = "onek8s/azure-landing-zone stacks/aks-policy/kubernetes" })

  parameters = jsonencode(merge(local.cluster_name_parameter, {
    effect = {
      type          = "String"
      defaultValue  = "Audit"
      allowedValues = ["audit", "Audit", "deny", "Deny", "disabled", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
    excludedNamespaces = {
      type         = "Array"
      defaultValue = ["kube-system", "gatekeeper-system", "azure-arc"]
      metadata     = { displayName = "Namespace exclusions" }
    }
    }, {
    # The constraint's own parameters
    for name, type in each.value.parameters : name => { type = type, metadata = { displayName = name } }
  }))

  policy_rule = jsonencode({
    if = local.cluster_rule
    then = {
      effect = "[parameters('effect')]"
      details = {
        templateInfo = {
          sourceType = "Base64Encoded"
          content    = filebase64("${path.module}/kubernetes/templates/${each.key}.yaml")
        }
        apiGroups          = each.value.api_groups
        kinds              = each.value.kinds
        excludedNamespaces = "[parameters('excludedNamespaces')]"
        values             = { for name, _ in each.value.parameters : name => "[parameters('${name}')]" }
      }
    }
  })
}

resource "azurerm_policy_definition" "kubernetes_mutation" {
  for_each = local.k8s_mutations

  name         = "onek8s-k8s-${each.key}"
  display_name = "OneK8s: ${each.value.display}"
  policy_type  = "Custom"
  mode         = "Microsoft.Kubernetes.Data"
  metadata     = jsonencode({ category = "Kubernetes", version = "1.0.0", source = "onek8s/azure-landing-zone stacks/aks-policy/kubernetes/mutations" })

  parameters = jsonencode(merge(local.cluster_name_parameter, {
    effect = {
      type          = "String"
      defaultValue  = "Mutate"
      allowedValues = ["mutate", "Mutate", "disabled", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
  }))

  policy_rule = jsonencode({
    if = local.cluster_rule
    then = {
      effect = "[parameters('effect')]"
      details = {
        mutationInfo = {
          sourceType = "Base64Encoded"
          content    = base64encode(each.value.content)
        }
      }
    }
  })
}

resource "azurerm_subscription_policy_assignment" "kubernetes" {
  for_each             = local.k8s_validations
  name                 = "aks-${local.env}-k8s-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.display}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_definition.kubernetes[each.value.template].id
  enforce              = each.value.always_deny || local.enforce
  location             = var.location
  parameters = jsonencode(merge({
    effect             = { value = each.value.always_deny ? "Deny" : "Audit" }
    clusterNamePattern = { value = each.value.clusters }
    excludedNamespaces = { value = each.value.excluded }
  }, { for name, value in each.value.values : name => { value = value } }))
}

resource "azurerm_subscription_policy_assignment" "kubernetes_mutation" {
  for_each             = local.k8s_mutations
  name                 = "aks-${local.env}-k8s-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.display}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_definition.kubernetes_mutation[each.key].id
  enforce              = true
  location             = var.location
  parameters = jsonencode({
    effect             = { value = "Mutate" }
    clusterNamePattern = { value = local.all_clusters }
  })
}
