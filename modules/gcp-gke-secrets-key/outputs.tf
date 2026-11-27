output "key_id" {
  description = "Key id for the cluster's database encryption. Built from the inputs, so it is known at plan time; depends_on orders it after the service agent grant."
  value       = "projects/${var.project_id}/locations/${var.region}/keyRings/${var.key_ring_name}/cryptoKeys/${var.key_name}"

  depends_on = [google_kms_crypto_key_iam_member.gke_agent]
}
