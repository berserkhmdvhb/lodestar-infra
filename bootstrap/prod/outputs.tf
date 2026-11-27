output "state_bucket" {
  description = "Name of the state bucket."
  value       = module.state.state_bucket
}

output "kms_key_id" {
  description = "Id of the KMS key for OpenTofu state encryption."
  value       = module.state.kms_key_id
}
