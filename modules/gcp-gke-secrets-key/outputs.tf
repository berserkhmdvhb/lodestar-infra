output "key_id" {
  description = "Key id for the cluster's database encryption; known only after the service agent may use the key."
  value       = google_kms_crypto_key.secrets.id

  depends_on = [google_kms_crypto_key_iam_member.gke_agent]
}
