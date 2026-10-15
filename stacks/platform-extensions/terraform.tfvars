location = "germanywestcentral"
# Its name in service tags (AzureCloud.germanywc)
service_tag_region = "germanywc"

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
# The lab has the internal exposure only (2026-10-15): two cells in the spec, dev-int-stateless-az1 (disabled in
# aks-terraform: zone 1 is not available to sub-aks-dev) and dev-int-stateless-az2 (running), with Finland's zone; Sweden's
# (int-se, index 2) is disabled there, so it has no prefixes here either. Disabling or adding a country is the
# zone's entry here, in shared/envs/dev.tfvars (isolation_zones.<zone>.enabled) and in environments/dev/policy.tfvars.
firewall_exposures = {
  int = {
    # The corporate path: the client VNet reaches the internal zones' gateways
    corporate = true
    environments = {
      dev = {
        # dev-int-stateless-az1 (disabled), -az2: snet-system and snet-apiserver (the private API server's
        # VNet integration, reached from the management network and the labfw VPN)
        system_prefixes     = ["172.22.0.0/24", "172.22.16.0/24", "172.22.15.0/28", "172.22.31.0/28"]
        shared_prefixes     = ["172.20.2.0/26"] # snet-shared-pe: the vaults' and the registry's private endpoints
        platform_key_vault  = "kv-onek8s-gwc-platform"
        container_registry  = "acronek8sdev"
        observability_fqdns = ["*.grafana.net"]
        zones = {
          int-fi = {
            prefixes        = ["172.22.1.0/24", "172.22.17.0/24"]
            key_vault       = "kv-onek8s-gwc-int-fi"
            fqdn_allow_list = ["login.microsoftonline.com"]
          }
        }
      }
    }
  }
}

# labfw (network mode labfw, network-mode.tfvars) in the hub instead of Azure Firewall: it enforces the internal
# exposure's child policy with the parent, and the spokes - the management and client VNets and the AKS cells - use
# its DNS proxy like a Firewall's. The default VM size, Standard_B2ats_v2 (Basv2, 2 vCPU), fits the lab's Basv2
# quota of 4 vCPUs; azure-lab-fw's optional E2E test VM is not deployed here.
labfw = {
  policy_exposure = "int"
  spoke_dns_proxy = true
  # WireGuard for machines outside Azure (the pool counts as management: API server private endpoints, jump host,
  # the cells' 443). Each client keeps its own private key; only public keys are listed here.
  vpn = {
    enabled = true
    peers = [
      { name = "olli-1", public_key = "pYIxZlOeS94bjS/n91t2skyVRRRauiwsVpSnXD9gYRI=", allowed_ips = ["10.0.12.10/32"] },
      # aks-terraform's GitHub-hosted runners (kubectl to the private API servers); its config is the secret
      # labfw-vpn--github-runners in kv-onek8s-gwc-platform. One peer: those jobs share the concurrency group labfw-vpn.
      { name = "github-runners", public_key = "MPuQuKwgLKKaJ5wiRWanumW+T2EVw6rHLmeDRCcuJgc=", allowed_ips = ["10.0.12.11/32"] },
    ]
  }
}
