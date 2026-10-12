output "policy_assignment_ids" {
  description = "The AKS platform's policy assignments on the environment subscription, by key."
  value       = { for k, a in azurerm_subscription_policy_assignment.aks : k => a.id }
}
