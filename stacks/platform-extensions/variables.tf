variable "location" {
  type        = string
  default     = "swedencentral"
  description = "Region of the platform landing zone (starter_location_01)."
}

variable "subscription_ids" {
  type        = map(string)
  description = "management (sub-mgmt) and connectivity (sub-hub) subscription IDs, the same as in accelerator/config/inputs.yaml."
}

variable "github_repository" {
  type        = string
  default     = "olljanat-ai/azure-landing-zone"
  description = "owner/name of the repository whose GitHub environments get OIDC access."
}

variable "state_storage_account_name" {
  type        = string
  description = "Terraform state storage account created by the accelerator bootstrap (BACKEND_AZURE_STORAGE_ACCOUNT_NAME)."
}

variable "state_resource_group_name" {
  type        = string
  description = "Resource group of the state storage account (BACKEND_AZURE_RESOURCE_GROUP_NAME)."
}

variable "state_container_name" {
  type        = string
  description = "State container (BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME)."
}

variable "management_address_space" {
  type        = string
  default     = "10.0.8.0/22"
  description = "Management VNet (aks-design picture 1): jump hosts, self-hosted CI runners and the private endpoints to every API server."
}

variable "client_address_space" {
  type        = string
  default     = "10.200.0.0/22"
  description = "Client VNet that simulates the corporate network in the build tenant (aks-design section 17)."
}

variable "environments" {
  type = map(object({
    subscription_id = string
    countries       = optional(map(number), { fi = 1, se = 2 })
    # Isolation zone => extra FQDNs the zone's applications may reach on the Internet (union of the zones'
    # application egress policies, aks-design section 16). Platform FQDNs are always allowed.
    zone_fqdn_allow_lists = optional(map(list(string)), {})
  }))
  description = "AKS platform environments that exist in this tenant. The build tenant only has dev (aks-design section 17)."
}

variable "jump_host_enabled" {
  type        = bool
  default     = true
  description = "Linux jump host in the management VNet, reached through Bastion, signed in with Entra ID."
}

variable "jump_host_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "client_vm_enabled" {
  type        = bool
  default     = true
  description = "Test client / load generator VM in the client VNet."
}

variable "client_vm_size" {
  type    = string
  default = "Standard_D2s_v5"
}

variable "admin_group_object_id" {
  type        = string
  default     = ""
  description = "Entra ID group of the platform team: Virtual Machine Administrator Login on the jump host and test client."
}

variable "github_runners" {
  type = object({
    count = optional(number, 2)
    # Runner image of the ALZ accelerator (accelerator-bootstrap-modules, runner_container_image_*)
    image_repository = optional(string, "https://github.com/Azure/avm-container-images-cicd-agents-and-runners")
    image_ref        = optional(string, "9b4c292e1a23c162d7801e019ab9f7f9099c3682")
    image_folder     = optional(string, "github-runner-aci")
    cpu              = optional(number, 2)
    memory           = optional(number, 4)
  })
  default     = {}
  description = "Self-hosted GitHub runners (Azure Container Instances) in the management VNet; the AKS environment and cell workflows run on them because Key Vault, ACR and the API servers are private."
}

variable "github_runner_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Fine-grained PAT with 'Administration: read and write' on the repository, used to register the runners. Leave empty to use a GitHub App instead, or to not create runners."
}

variable "github_runner_app_id" {
  type        = string
  default     = ""
  description = "GitHub App ID for runner registration (alternative to the PAT)."
}

variable "github_runner_app_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Private key (PEM) of the GitHub App."
}

variable "tags" {
  type = map(string)
  default = {
    deployed_by = "terraform"
    platform    = "aks"
    tenant      = "build"
  }
}

variable "hub_bastion_subnet_prefix" {
  type        = string
  default     = "10.0.0.64/26"
  description = "AzureBastionSubnet of the hub (primary_bastion_subnet_address_prefix in platform-landing-zone.tfvars)."
}

variable "network_mode" {
  type        = string
  default     = "firewall"
  description = "firewall (design) or sandbox (no Azure Firewall: direct peerings, NSGs, NAT gateways) – network-mode.tfvars."
  validation {
    condition     = contains(["firewall", "sandbox"], var.network_mode)
    error_message = "firewall or sandbox."
  }
}
