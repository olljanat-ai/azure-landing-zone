# Address plan of OneK8s design section 8 ("VNets and address plan"). Pure computation, no resources:
#
#   environment /12 -> platform /16 (index 0) + one /16 per country
#   country /16     -> zone /17: int (first half), ext (second half)
#   zone /17        -> frontend /18 (cells + internal entry point) and backend /18 (stateful cluster)
#   zone /17        -> one /20 per slot: sl-az1, sl-az2, sl-az3, edge, sf (+ reserve)
#   platform /16    -> one /20 control plane zone per slot, laid out in the same way
#
# Every cluster VNet gets its control plane /20 and one /20 per isolation zone as separate address spaces.
locals {
  slots = {
    sl-az1 = 0
    sl-az2 = 1
    sl-az3 = 2
    edge   = 3
    sf     = 4
  }
  exposures = { int = 0, ext = 1 }

  environment_prefix = cidrsubnet(var.base_prefix, 4, var.environment_indexes[var.environment])
  platform_prefix    = cidrsubnet(local.environment_prefix, 4, 0)
  country_prefixes   = { for c, i in var.countries : c => cidrsubnet(local.environment_prefix, 4, i) }

  zones = merge([
    for c, prefix in local.country_prefixes : {
      for e, i in local.exposures : "${e}-${c}" => {
        name     = "${e}-${c}"
        short    = "${e}${c}" # NAP NodePool / node pool name: intfi, extse, ...
        exposure = e
        country  = c
        prefix   = cidrsubnet(prefix, 1, i)
        frontend = cidrsubnet(cidrsubnet(prefix, 1, i), 1, 0)
        backend  = cidrsubnet(cidrsubnet(prefix, 1, i), 1, 1)
        slots    = { for s, si in local.slots : s => cidrsubnet(cidrsubnet(prefix, 1, i), 3, si) }
      }
    }
  ]...)

  control_plane = { for s, si in local.slots : s => cidrsubnet(local.platform_prefix, 4, si) }

  # Subnet layout of a stateless cell (OneK8s design picture 2), per slot sl-az<N>
  cells = {
    for s in ["sl-az1", "sl-az2", "sl-az3"] : s => {
      address_spaces = concat([local.control_plane[s]], [for z in values(local.zones) : z.slots[s]])
      control_plane = {
        prefix             = local.control_plane[s]
        snet_system        = cidrsubnet(local.control_plane[s], 4, 0)  # /24 system node pool
        snet_apiserver     = cidrsubnet(local.control_plane[s], 8, 16) # /28 delegated, API server ILB
        snet_apiserver_pls = cidrsubnet(local.control_plane[s], 8, 17) # /28 Private Link Service to the management VNet
        snet_platform_pe   = cidrsubnet(local.control_plane[s], 7, 9)  # /27 platform Key Vault + KMS private endpoints
      }
      zones = {
        for k, z in local.zones : k => {
          prefix     = z.slots[s]
          snet_nodes = cidrsubnet(z.slots[s], 1, 0)  # /21 NAP nodes of the zone
          snet_ilb   = cidrsubnet(z.slots[s], 7, 64) # /27 Traefik internal load balancer (+ Private Link Service for ext zones)
          snet_pe    = cidrsubnet(z.slots[s], 7, 65) # /27 zone Key Vault private endpoint
        }
      }
    }
  }

  # Backend spoke vnet-<env>-sf: exists from day one with the PaaS private endpoints and the ACR, the stateful
  # cluster's node / pod subnets are reserved and created only with the cluster.
  backend = {
    address_spaces = concat([local.control_plane["sf"]], [for z in values(local.zones) : z.slots["sf"]])
    control_plane = {
      prefix         = local.control_plane["sf"]
      snet_system    = cidrsubnet(local.control_plane["sf"], 4, 0)
      snet_apiserver = cidrsubnet(local.control_plane["sf"], 8, 16)
      snet_shared_pe = cidrsubnet(local.control_plane["sf"], 6, 8) # /26 ACR, platform and zone Key Vaults (shared)
    }
    zones = {
      for k, z in local.zones : k => {
        prefix     = z.slots["sf"]
        snet_nodes = cidrsubnet(z.slots["sf"], 3, 0)  # /23 reserved for the stateful node pools
        snet_ilb   = cidrsubnet(z.slots["sf"], 7, 16) # /27 reserved: application internal load balancers
        snet_pe    = cidrsubnet(z.slots["sf"], 6, 9)  # /26 the zone's PaaS private endpoints
        snet_pods  = cidrsubnet(z.slots["sf"], 1, 1)  # /21 reserved: stateful pod subnet
      }
    }
  }

  # Edge VNet vnet-<env>-edge: one delegated NGINXaaS subnet per internal zone, inside the zone's edge /20.
  edge = {
    address_spaces = [for z in values(local.zones) : z.slots["edge"] if z.exposure == "int"]
    zones = {
      for k, z in local.zones : k => {
        prefix     = z.slots["edge"]
        snet_nginx = cidrsubnet(z.slots["edge"], 4, 0) # /24 delegated to NGINX.NGINXPLUS/nginxDeployments
      } if z.exposure == "int"
    }
  }
}
