location = "swedencentral"

# The same subscriptions as accelerator/config/inputs.yaml – replace
subscription_ids = {
  management   = "2e73156d-6206-4354-b599-1f4e31333a7d" # sub-mgmt
  connectivity = "56b07081-ca7e-4343-b000-bc0998a8c347" # sub-hub
}

# Add dev once sub-aks-dev exists: creates the AKS deployment identities
environments = {
  # dev = {
  #   subscription_id = "<sub-aks-dev>"
  # }
}

# state_storage_account_name / state_resource_group_name / state_container_name come from the GitHub variables
# BACKEND_AZURE_* (TF_VAR_*), github_runner_token / github_runner_app_* from GitHub secrets.
