# Stateless cluster aks-<env>-sl-az<N> (aks-design sections 3, 4, 8, 13, 14, 16 and 18). azapi because node auto
# provisioning, ACNS eBPF host routing and API Server VNet Integration are set with fields of the 2026-05-01 API.
resource "azapi_resource" "cluster" {
  type      = "Microsoft.ContainerService/managedClusters@2026-05-01"
  name      = local.cluster_name
  parent_id = azurerm_resource_group.cell.id
  location  = var.location
  tags      = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  body = {
    sku = {
      name = "Base"
      tier = var.sku_tier
    }
    properties = {
      kubernetesVersion = local.kubernetes_version
      dnsPrefix         = local.cluster_name
      nodeResourceGroup = "rg-${local.cluster_name}-nodes-${var.location}"
      supportPlan       = "KubernetesOfficial"
      enableRBAC        = true

      # Entra ID only, Azure RBAC for Kubernetes, no local accounts
      disableLocalAccounts = true
      aadProfile = {
        managed             = true
        enableAzureRBAC     = true
        adminGroupObjectIDs = var.admin_group_object_ids
        tenantID            = data.azurerm_client_config.current.tenant_id
      }

      # Section 3: private API server projected into the delegated snet-apiserver; reached from the management
      # VNet only through a Private Link Service + private endpoint (main.api-access.tf)
      apiServerAccessProfile = {
        enablePrivateCluster           = true
        enableVnetIntegration          = true
        subnetId                       = azurerm_subnet.this["apiserver"].id
        privateDNSZone                 = "system"
        enablePrivateClusterPublicFQDN = false
        disableRunCommand              = false # `az aks command invoke` for pipeline smoke tests
      }

      # Section 16: Azure CNI Overlay powered by Cilium, ACNS with FQDN policies and eBPF host routing.
      # Egress only through the hub Firewall (sandbox network mode: the cell's NAT gateway).
      networkProfile = {
        networkPlugin     = "azure"
        networkPluginMode = "overlay"
        networkDataplane  = "cilium"
        networkPolicy     = "cilium"
        podCidr           = var.pod_cidr
        serviceCidr       = var.service_cidr
        dnsServiceIP      = var.dns_service_ip
        outboundType      = local.firewall ? "userDefinedRouting" : "userAssignedNATGateway"
        loadBalancerSku   = "standard"
        advancedNetworking = {
          enabled = true
          observability = {
            enabled = true
          }
          security = {
            enabled                 = true
            advancedNetworkPolicies = "FQDN"
          }
          performance = {
            accelerationMode = "BpfVeth"
          }
        }
      }

      # Section 4: node auto provisioning; every NAP node belongs to a zone's NodePool (defined by Flux)
      nodeProvisioningProfile = {
        mode             = "Auto"
        defaultNodePools = "None"
      }

      agentPoolProfiles = [{
        name                   = "system"
        mode                   = "System"
        type                   = "VirtualMachineScaleSets"
        vmSize                 = var.system_pool.vm_size
        count                  = var.system_pool.node_count
        enableAutoScaling      = false
        maxPods                = var.system_pool.max_pods
        availabilityZones      = [local.az]
        osType                 = "Linux"
        osSKU                  = "AzureLinux3"
        osDiskType             = "Ephemeral"
        enableEncryptionAtHost = true
        vnetSubnetID           = azurerm_subnet.this["system"].id
        orchestratorVersion    = local.kubernetes_version
        nodeTaints             = ["CriticalAddonsOnly=true:NoSchedule"]
        upgradeSettings = {
          maxSurge = "33%"
        }
        securityProfile = {
          sshAccess = "Disabled"
        }
      }]

      # Section 18: OS disks of all nodes with the cluster's disk key
      diskEncryptionSetID = azurerm_disk_encryption_set.cluster.id

      identityProfile = {
        kubeletidentity = {
          resourceId = azurerm_user_assigned_identity.kubelet.id
          clientId   = azurerm_user_assigned_identity.kubelet.client_id
          objectId   = azurerm_user_assigned_identity.kubelet.principal_id
        }
      }

      oidcIssuerProfile = {
        enabled = true
      }

      securityProfile = merge({
        workloadIdentity = {
          enabled = true
        }
        # Section 18: KMS etcd encryption with a private platform vault (needs API Server VNet Integration)
        azureKeyVaultKms = {
          enabled               = true
          keyId                 = azurerm_key_vault_key.cluster["kms"].id
          keyVaultNetworkAccess = "Private"
          keyVaultResourceId    = data.azurerm_key_vault.platform.id
        }
        imageCleaner = {
          enabled       = true
          intervalHours = 48
        }
        }, var.defender_enabled ? {
        defender = {
          logAnalyticsWorkspaceResourceId = module.platform.log_analytics_workspace_id
          securityMonitoring = {
            enabled = true
          }
        }
      } : {})

      addonProfiles = {
        # Section 14: the single policy engine
        azurepolicy = {
          enabled = true
        }
        # Section 6: the Secrets Store CSI driver is never used – External Secrets Operator only
        azureKeyvaultSecretsProvider = {
          enabled = false
        }
        # Container Insights: off in the lab (Log Analytics ingestion is its main cost)
        omsagent = merge({
          enabled = var.container_insights_enabled
          }, var.container_insights_enabled ? {
          config = {
            logAnalyticsWorkspaceResourceID = module.platform.log_analytics_workspace_id
            useAADAuth                      = "true"
          }
        } : {})
      }

      # Section 12: the version pipeline decides, AKS never upgrades on its own
      autoUpgradeProfile = {
        upgradeChannel       = "none"
        nodeOSUpgradeChannel = "None"
      }

      # Stateless: no persistent volumes (Azure Policy rejects PVCs)
      storageProfile = {
        diskCSIDriver = {
          enabled = true
        }
        fileCSIDriver = {
          enabled = false
        }
        blobCSIDriver = {
          enabled = false
        }
        snapshotController = {
          enabled = false
        }
      }
    }
  }

  response_export_values = [
    "properties.privateFQDN",
    "properties.nodeResourceGroup",
    "properties.oidcIssuerProfile.issuerURL",
    "properties.currentKubernetesVersion",
  ]

  timeouts {
    create = "90m"
    update = "90m"
    delete = "60m"
  }

  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_subnet_network_security_group_association.this,
    azurerm_subnet_route_table_association.this,
    azurerm_virtual_network_peering.cell_to_hub,
    azurerm_virtual_network_peering.hub_to_cell,
    azurerm_subnet_nat_gateway_association.nodes,
    azurerm_virtual_network_peering.cell_to_environment,
    azurerm_virtual_network_peering.environment_to_cell,
  ]

  lifecycle {
    # NAP and the version pipeline own these at runtime
    ignore_changes = [body.properties.agentPoolProfiles[0].count]
  }
}

locals {
  cluster_private_fqdn = azapi_resource.cluster.output.properties.privateFQDN
  node_resource_group  = azapi_resource.cluster.output.properties.nodeResourceGroup
  oidc_issuer_url      = azapi_resource.cluster.output.properties.oidcIssuerProfile.issuerURL
}

resource "azurerm_monitor_diagnostic_setting" "cluster" {
  name                           = "diag-to-law"
  target_resource_id             = azapi_resource.cluster.id
  log_analytics_workspace_id     = module.platform.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "kube-audit-admin"
  }
  enabled_log {
    category = "kube-apiserver"
  }
  enabled_log {
    category = "guard"
  }
  enabled_log {
    category = "kube-controller-manager"
  }
  enabled_log {
    category = "cluster-autoscaler"
  }
}
