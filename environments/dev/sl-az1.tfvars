# Cell sl-az1 of dev: fast update speed, second latest GA minor (N-1), patches 1 week after release
# (aks-design section 12). Everything in availability zone 1.
environment     = "dev"
cell            = "sl-az1"
location        = "swedencentral"
subscription_id = "00000000-0000-0000-0000-000000000003" # sub-aks-dev – replace

platform_subscription_ids = {
  management   = "00000000-0000-0000-0000-000000000001" # sub-mgmt – replace
  connectivity = "00000000-0000-0000-0000-000000000002" # sub-hub  – replace
}

countries   = { fi = 1, se = 2 }
name_suffix = "b1"
dns_domain  = "example-test.com"

# null: newest patch of N-1. The version pipeline writes the explicit version here.
kubernetes_version      = null
kubernetes_minor_offset = 1

system_pool = {
  vm_size    = "Standard_D4ds_v5"
  node_count = 3
}

admin_group_object_ids = [] # Entra ID group of the platform team

# Fleet repository (aks-design section 10); null until it exists
fleet = null
# fleet = {
#   kind = "GitRepository"
#   url  = "https://github.com/olljanat-ai/aks-fleet"
# }
