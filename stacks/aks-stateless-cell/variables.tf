variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd."
}

variable "cell" {
  type        = string
  description = "Stateless cell = cluster slot: sl-az1, sl-az2 or sl-az3. The cell runs entirely in availability zone <N>."
  validation {
    condition     = contains(["sl-az1", "sl-az2", "sl-az3"], var.cell)
    error_message = "sl-az1, sl-az2 or sl-az3."
  }
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "subscription_id" {
  type        = string
  description = "Environment subscription (sub-aks-<env>)."
}

variable "platform_subscription_ids" {
  type        = map(string)
  description = "management (sub-mgmt) and connectivity (sub-hub) subscription IDs."
}

variable "countries" {
  type        = map(number)
  default     = { fi = 1, se = 2 }
  description = "Must be the same as in the environment stack."
}

variable "name_suffix" {
  type        = string
  description = "Same name_suffix as the environment stack (Key Vault names)."
}

variable "container_registry" {
  type = object({
    name                = string
    resource_group_name = string
  })
  description = "The environment's container registry, created by onek8s/aks-terraform (shared/): the kubelet identity gets AcrPull on it."
}

variable "dns_domain" {
  type        = string
  description = "The platform's one DNS domain (onek8s.lol); names are <zone>.<env>.<domain> (cluster-vars)."
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes version of control plane and system pool, written by the version pipeline (OneK8s design section 12). null: the newest patch of the minor given by kubernetes_minor_offset."
}

variable "kubernetes_minor_offset" {
  type        = number
  default     = 1
  description = "Update speed when kubernetes_version is null: 1 = second latest GA minor (N-1, sl-az1, fast), 2 = N-2 (sl-az2/sl-az3, slow)."
}

variable "sku_tier" {
  type        = string
  default     = "Free"
  description = "AKS pricing tier. Standard: uptime SLA (the design); Free (lab): no SLA, no control plane fee."
  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "Free or Standard."
  }
}

variable "system_pool" {
  type = object({
    vm_size    = optional(string, "Standard_D4ds_v5") # VNet encryption + encryption at host + ephemeral OS disk
    node_count = optional(number, 1)                  # 3 in the design
    max_pods   = optional(number, 110)
  })
  default     = {}
  description = "System node pool: fixed node count, tainted CriticalAddonsOnly, pinned to the cell's AZ (OneK8s design sections 3 and 4)."
}

variable "pod_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "Overlay pod CIDR; the same in every stateless cluster, outside all VNet and on-premises prefixes."
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "172.16.0.10"
}

variable "admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Entra ID groups with cluster admin (Azure RBAC for Kubernetes); in acc/prd only through PIM."
}

variable "fleet" {
  type = object({
    kind       = optional(string, "GitRepository") # GitRepository while prototyping, OCIRepository (environment ACR) later
    url        = string
    branch     = optional(string, "main")
    tag        = optional(string) # OCIRepository: <env>-<cell> (one tag per cell, OneK8s design section 10)
    path       = optional(string) # default ./clusters/<env>/<cell>
    sync_every = optional(number, 600)
  })
  default     = null
  description = "Fleet repository reconciled by the GitOps extension (Flux). null: install Flux without configuration."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "network_mode" {
  type        = string
  default     = "firewall"
  description = "firewall (design: outbound type userDefinedRouting via the hub Firewall) or sandbox (outbound type userAssignedNATGateway, direct peerings to the backend and edge VNets, NSGs only) – network-mode.tfvars."
  validation {
    condition     = contains(["firewall", "sandbox"], var.network_mode)
    error_message = "firewall or sandbox."
  }
}
