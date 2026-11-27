# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_id     = "your-project-id"
  project_number = "123456789012"
}

run "key_ring_is_in_the_region" {
  command = plan

  assert {
    condition     = google_kms_key_ring.gke.name == "gke" && google_kms_key_ring.gke.location == "europe-west1" && google_kms_key_ring.gke.project == "your-project-id"
    error_message = "ring gke in the cluster's region"
  }
}

run "key_encrypts_and_rotates_every_90_days" {
  command = plan

  assert {
    condition = (
      google_kms_crypto_key.secrets.name == "secrets"
      && google_kms_crypto_key.secrets.purpose == "ENCRYPT_DECRYPT"
      && google_kms_crypto_key.secrets.rotation_period == "7776000s"
    )
    error_message = "key secrets, ENCRYPT_DECRYPT, rotation 7776000s"
  }
}

run "rotation_and_region_are_variables" {
  command = plan

  variables {
    region          = "europe-west4"
    rotation_period = "2592000s"
  }

  assert {
    condition     = google_kms_key_ring.gke.location == "europe-west4" && google_kms_crypto_key.secrets.rotation_period == "2592000s"
    error_message = "region and rotation follow the variables"
  }
}

run "gke_service_agent_may_use_the_key" {
  command = plan

  assert {
    condition = (
      google_kms_crypto_key_iam_member.gke_agent.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
      && google_kms_crypto_key_iam_member.gke_agent.member == "serviceAccount:service-123456789012@container-engine-robot.iam.gserviceaccount.com"
    )
    error_message = "exact role and GKE service agent built from the project number"
  }
}

run "project_number_must_be_digits" {
  command = plan

  variables {
    project_number = "not-a-number"
  }

  expect_failures = [var.project_number]
}

run "key_id_is_known_at_plan" {
  command = plan

  assert {
    condition     = output.key_id == "projects/your-project-id/locations/europe-west1/keyRings/gke/cryptoKeys/secrets"
    error_message = "key_id is built from the inputs so the cluster's ENCRYPTED state is known at plan"
  }
}
