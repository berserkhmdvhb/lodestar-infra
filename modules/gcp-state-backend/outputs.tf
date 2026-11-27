output "state_bucket" {
  description = "Name of the state bucket."
  value       = google_storage_bucket.state.name
}

output "kms_key_id" {
  description = "Id of the KMS key for OpenTofu state encryption."
  value       = google_kms_crypto_key.state.id
}
