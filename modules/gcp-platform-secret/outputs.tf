output "secret_ids" {
  description = "Map of secret id to the secret id."
  value       = { for k, s in google_secret_manager_secret.this : k => s.secret_id }
}
