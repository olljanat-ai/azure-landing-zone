# AKS policy assignments of dev (OneK8s design section 14), stacks/aks-policy
environment     = "dev"
location        = "swedencentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars and environments/dev/environment.tfvars
policy_enforcement_mode = "DoNotEnforce"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars)
container_registry_name = "acronek8sdev"

# The platform's own Kubernetes policies (stacks/aks-policy/kubernetes.tf): the zones' domain and which
# clusters are stateless or stateful, as onek8s/aks-terraform names them (envs/*.tfvars)
zone_domain_suffix          = "dev.onek8s.lol"
cluster_resource_group_name = "rg-aks-dev"
stateless_cluster_names     = ["aks-dev-stateless-az1", "aks-dev-stateless-az2"]
stateful_cluster_name       = "aks-dev-stateful"
