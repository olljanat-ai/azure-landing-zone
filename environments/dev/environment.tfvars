# dev environment of the build tenant (aks-design sections 9 and 17)
environment     = "dev"
location        = "swedencentral"
subscription_id = "00000000-0000-0000-0000-000000000003" # sub-aks-dev – replace

platform_subscription_ids = {
  management   = "00000000-0000-0000-0000-000000000001" # sub-mgmt – replace
  connectivity = "00000000-0000-0000-0000-000000000002" # sub-hub  – replace
}

countries   = { fi = 1, se = 2 }
name_suffix = "b1" # makes kv-dev-<zone>-b1 / acrdevaksb1 globally unique – change if taken
dns_domain  = "example-test.com"

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars
policy_enforcement_mode = "DoNotEnforce"

front_door_enabled = true
nginxaas_enabled   = false

# Reference application of the acceptance tests (aks-design section 17) in every zone
applications = {
  # refapp = { zone = "int-fi", needs_secrets = true }
}
