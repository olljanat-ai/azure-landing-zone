# AKS policy assignments of dev (OneK8s design section 14), stacks/aks-policy
environment     = "dev"
location        = "swedencentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars and environments/dev/environment.tfvars
policy_enforcement_mode = "DoNotEnforce"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars)
container_registry_name = "acronek8sdev"
