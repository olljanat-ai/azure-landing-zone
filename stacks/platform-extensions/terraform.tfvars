location = "swedencentral"

# The same subscriptions as accelerator/config/inputs.yaml – replace
subscription_ids = {
  management   = "2e73156d-6206-4354-b599-1f4e31333a7d" # sub-mgmt
  connectivity = "56b07081-ca7e-4343-b000-bc0998a8c347" # sub-hub
}

# The AKS deployment identities of each environment. dev's apply identity also deploys from onek8s/aks-terraform
# (GitHub environment `dev`): the clusters, the container registry and the public DNS records.
environments = {
  dev = {
    subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev
    deployment_repositories = {
      aks-terraform = {
        subject_prefix     = "repo:onek8s@340519759/aks-terraform@1340382905"
        github_environment = "dev"
      }
    }
  }
}

# state_storage_account_name / state_resource_group_name / state_container_name come from the GitHub variables
# BACKEND_AZURE_* (TF_VAR_*), github_runner_token / github_runner_app_* from GitHub secrets.

# The Firewall Policies (main.firewall.policies.tf, design D53): the prefixes of onek8s/aks-terraform
# shared/envs/dev.tfvars - every cell's /20 with snet-system the first /24 and each zone the /24 of its index.
# The lab has the external exposure only.
firewall_exposures = {
  ext = {
    environments = {
      dev = {
        system_prefixes     = ["172.21.0.0/24", "172.21.16.0/24"] # dev-ext-stateless-az1, -az2
        platform_key_vault  = "kv-onek8s-dev-platform"
        container_registry  = "acronek8sdev"
        observability_fqdns = ["*.grafana.net"]
        zones = {
          ext-fi = {
            prefixes        = ["172.21.3.0/24", "172.21.19.0/24"]
            key_vault       = "kv-onek8s-dev-ext-fi"
            fqdn_allow_list = ["login.microsoftonline.com", "api.github.com"]
          }
          ext-se = {
            prefixes        = ["172.21.4.0/24", "172.21.20.0/24"]
            key_vault       = "kv-onek8s-dev-ext-se"
            fqdn_allow_list = ["login.microsoftonline.com"]
          }
        }
      }
    }
  }
}
