# Cell sl-az1 of dev: fast update speed, second latest GA minor (N-1), patches 1 week after release
# (aks-design section 12). Everything in availability zone 1.
environment     = "dev"
cell            = "sl-az1"
location        = "swedencentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

platform_subscription_ids = {
  management   = "2e73156d-6206-4354-b599-1f4e31333a7d" # sub-mgmt – replace
  connectivity = "56b07081-ca7e-4343-b000-bc0998a8c347" # sub-hub  – replace
}

countries   = { fi = 1, se = 2 }
name_suffix = "b1"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars), not by the landing zone
container_registry = {
  name                = "acronek8sdev"
  resource_group_name = "rg-aks-dev"
}
dns_domain = "example-test.com"

# null: newest patch of N-1. The version pipeline writes the explicit version here.
kubernetes_version      = null
kubernetes_minor_offset = 1

# Lab: Free tier and one system node. The design: sku_tier = "Standard", node_count = 3.
sku_tier = "Free"
system_pool = {
  vm_size    = "Standard_D4ds_v5"
  node_count = 1
}

admin_group_object_ids = [] # Entra ID group of the platform team

# Fleet repository (aks-design section 10); null until it exists
fleet = null
# fleet = {
#   kind = "GitRepository"
#   url  = "https://github.com/onek8s/aks-fleet"
# }
