output "budget_name" {
  description = "Full budget resource name, or null when disabled."
  value       = one(google_billing_budget.this[*].name)
}
