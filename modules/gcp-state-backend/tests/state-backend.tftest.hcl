# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {
  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-0@gs-project-accounts.iam.gserviceaccount.com"
      member        = "serviceAccount:service-0@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

variables {
  state_bucket_name = "my-tofu-state-bucket"
}

run "bucket_is_locked_down" {
  command = plan

  assert {
    condition     = google_storage_bucket.state.versioning[0].enabled == true
    error_message = "versioning must be on"
  }
  assert {
    condition     = google_storage_bucket.state.uniform_bucket_level_access == true
    error_message = "uniform bucket-level access must be on"
  }
  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced"
    error_message = "public access prevention must be enforced"
  }
  assert {
    condition     = google_storage_bucket.state.force_destroy == false
    error_message = "force_destroy must be false"
  }
  assert {
    condition     = length(google_storage_bucket.state.retention_policy) == 0
    error_message = "no retention policy (a locked one is irreversible)"
  }
  assert {
    condition     = google_storage_bucket.state.location == "europe-west1"
    error_message = "location must follow var.region"
  }
}

run "noncurrent_rule_needs_both_conditions" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.state.lifecycle_rule) == 1
    error_message = "exactly one lifecycle rule"
  }
  assert {
    condition     = one(one(google_storage_bucket.state.lifecycle_rule).action).type == "Delete"
    error_message = "the rule deletes"
  }
  assert {
    condition = (
      one(one(google_storage_bucket.state.lifecycle_rule).condition).num_newer_versions == 20
      && one(one(google_storage_bucket.state.lifecycle_rule).condition).days_since_noncurrent_time == 90
    )
    error_message = "both num_newer_versions and days_since_noncurrent_time must be set"
  }
}

run "key_rotates_every_90_days_by_default" {
  command = plan

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "7776000s"
    error_message = "default rotation must be 7776000s (90 days)"
  }
}

run "key_rotates" {
  command = plan

  variables {
    kms_rotation_period = "2592000s"
  }

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "2592000s"
    error_message = "rotation period must equal the variable"
  }
  assert {
    condition     = google_kms_crypto_key.state.purpose == "ENCRYPT_DECRYPT"
    error_message = "purpose must be ENCRYPT_DECRYPT"
  }
}

run "no_iam_by_default" {
  command = plan

  assert {
    condition = (
      length(google_storage_bucket_iam_member.admins) == 0
      && length(google_kms_crypto_key_iam_member.admins) == 0
      && length(google_kms_crypto_key_iam_member.gcs_agent) == 0
    )
    error_message = "no IAM bindings without state_admins or CMEK"
  }
  assert {
    condition     = length(google_storage_bucket.state.encryption) == 0
    error_message = "no CMEK by default"
  }
}

run "state_admins_get_bucket_and_key_bindings" {
  command = plan

  variables {
    state_admins = ["serviceAccount:ci@my-project.iam.gserviceaccount.com", "user:a@example.com"]
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.admins) == 2
    error_message = "one bucket binding per admin"
  }
  assert {
    condition     = length(google_kms_crypto_key_iam_member.admins) == 2
    error_message = "one key binding per admin"
  }
  assert {
    condition     = alltrue([for m in google_storage_bucket_iam_member.admins : m.role == "roles/storage.objectAdmin"])
    error_message = "bucket role is objectAdmin"
  }
  assert {
    condition     = alltrue([for m in google_kms_crypto_key_iam_member.admins : m.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"])
    error_message = "key role is encrypterDecrypter"
  }
  assert {
    condition = alltrue([for m in concat(
      values(google_storage_bucket_iam_member.admins),
      values(google_kms_crypto_key_iam_member.admins),
      google_kms_crypto_key_iam_member.gcs_agent,
    ) : !contains(["allUsers", "allAuthenticatedUsers"], m.member)])
    error_message = "no public IAM members"
  }
}

run "cmek_wires_key_and_service_agent" {
  command = plan

  variables {
    bucket_cmek_enabled = true
  }

  assert {
    condition     = length(google_storage_bucket.state.encryption) == 1
    error_message = "bucket default encryption must be set"
  }
  assert {
    condition     = length(google_kms_crypto_key_iam_member.gcs_agent) == 1
    error_message = "the GCS service agent needs the key"
  }
  assert {
    condition     = one(google_kms_crypto_key_iam_member.gcs_agent).role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    error_message = "agent role is encrypterDecrypter"
  }
  assert {
    condition     = one(google_storage_bucket.state.encryption).default_kms_key_name == google_kms_crypto_key.state.id
    error_message = "default_kms_key_name must be the state key"
  }
}

run "bad_bucket_name_rejected" {
  command = plan

  variables {
    state_bucket_name = "Bad_Name"
  }

  expect_failures = [var.state_bucket_name]
}

run "all_users_admin_rejected" {
  command = plan

  variables {
    state_admins = ["allUsers"]
  }

  expect_failures = [var.state_admins]
}

run "all_authenticated_users_admin_rejected" {
  command = plan

  variables {
    state_admins = ["allAuthenticatedUsers"]
  }

  expect_failures = [var.state_admins]
}

run "rotation_without_suffix_rejected" {
  command = plan

  variables {
    kms_rotation_period = "7776000"
  }

  expect_failures = [var.kms_rotation_period]
}

run "rotation_below_one_day_rejected" {
  command = plan

  variables {
    kms_rotation_period = "3600s"
  }

  expect_failures = [var.kms_rotation_period]
}

run "rotation_not_numeric_rejected" {
  command = plan

  variables {
    kms_rotation_period = "abcs"
  }

  expect_failures = [var.kms_rotation_period]
}

run "zero_versions_kept_rejected" {
  command = plan

  variables {
    noncurrent_versions_kept = 0
  }

  expect_failures = [var.noncurrent_versions_kept]
}

run "negative_days_rejected" {
  command = plan

  variables {
    noncurrent_days = -1
  }

  expect_failures = [var.noncurrent_days]
}

run "double_dot_bucket_name_rejected" {
  command = plan

  variables {
    state_bucket_name = "my..state-bucket"
  }

  expect_failures = [var.state_bucket_name]
}
