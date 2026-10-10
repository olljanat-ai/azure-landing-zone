location = "swedencentral"

# The same subscriptions as accelerator/config/inputs.yaml – replace
subscription_ids = {
  management   = "00000000-0000-0000-0000-000000000001" # sub-mgmt
  connectivity = "00000000-0000-0000-0000-000000000002" # sub-hub
}

environments = {
  dev = {
    subscription_id = "00000000-0000-0000-0000-000000000003" # sub-aks-dev
  }
}

# state_storage_account_name / state_resource_group_name / state_container_name come from the GitHub variables
# BACKEND_AZURE_* (TF_VAR_*), github_runner_token / github_runner_app_* from GitHub secrets.
