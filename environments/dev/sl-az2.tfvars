# Cell sl-az2 of dev: slow update speed, one minor behind sl-az1 (N-2), patches 1 month after release
# (aks-design section 12). Everything in availability zone 2.
environment     = "dev"
cell            = "sl-az2"
location        = "swedencentral"
subscription_id = "00000000-0000-0000-0000-000000000003" # sub-aks-dev – replace

platform_subscription_ids = {
  management   = "00000000-0000-0000-0000-000000000001" # sub-mgmt – replace
  connectivity = "00000000-0000-0000-0000-000000000002" # sub-hub  – replace
}

countries   = { fi = 1, se = 2 }
name_suffix = "b1"
dns_domain  = "example-test.com"

# null: newest patch of N-2. The version pipeline writes the explicit version here.
kubernetes_version      = null
kubernetes_minor_offset = 2

system_pool = {
  vm_size    = "Standard_D4ds_v5"
  node_count = 3
}

admin_group_object_ids = [] # Entra ID group of the platform team

# Fleet repository (aks-design section 10); null until it exists
fleet = null
# fleet = {
#   kind = "GitRepository"
#   url  = "https://github.com/onek8s/aks-fleet"
# }
