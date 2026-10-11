# dev environment of the build tenant (OneK8s design sections 9 and 17)
environment     = "dev"
location        = "swedencentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

platform_subscription_ids = {
  management   = "2e73156d-6206-4354-b599-1f4e31333a7d" # sub-mgmt – replace
  connectivity = "56b07081-ca7e-4343-b000-bc0998a8c347" # sub-hub  – replace
}

countries   = { fi = 1, se = 2 }
name_suffix = "b1" # makes kv-dev-<zone>-b1 globally unique – change if taken
dns_domain  = "example-test.com"

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars
policy_enforcement_mode = "DoNotEnforce"

# Lab SKUs. The design: front_door_enabled = true, key_vault_sku = "premium".
front_door_enabled = false
nginxaas_enabled   = false
key_vault_sku      = "standard"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars), not by the landing zone
container_registry = {
  name                = "acronek8sdev"
  resource_group_name = "rg-aks-dev"
}

# Reference application of the acceptance tests (OneK8s design section 17) in every zone
applications = {
  # refapp = { zone = "int-fi", needs_secrets = true }
}
