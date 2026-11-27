locals {
  # The GKE service agent of the project; GKE reads and writes the key as this identity.
  gke_agent = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}

# Key rings and keys can never be deleted in Cloud KMS, and losing the key makes every Secret unreadable.
resource "google_kms_key_ring" "gke" {
  name     = var.key_ring_name
  project  = var.project_id
  location = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "secrets" {
  name            = var.key_name
  key_ring        = google_kms_key_ring.gke.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = var.rotation_period

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gke_agent" {
  crypto_key_id = google_kms_crypto_key.secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.gke_agent
}
