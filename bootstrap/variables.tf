variable "project_id" {
  type        = string
  description = "GCP project that holds the state bucket and the KMS key."
}

variable "region" {
  type        = string
  description = "Location of the bucket and the key ring."
  default     = "europe-west1"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique name of the state bucket."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be 3-63 characters: lowercase letters, digits, '-', '_' or '.', starting and ending with a letter or digit."
  }
}

variable "kms_key_ring_name" {
  type        = string
  description = "Name of the KMS key ring."
  default     = "tofu-state"
}

variable "kms_key_name" {
  type        = string
  description = "Name of the KMS key used for OpenTofu state encryption."
  default     = "tofu-state"
}

variable "kms_rotation_period" {
  type        = string
  description = "Automatic key rotation period, in seconds (default 90 days)."
  default     = "7776000s"
}

variable "bucket_cmek_enabled" {
  type        = bool
  description = "Also encrypt the bucket's objects with the KMS key (default encryption)."
  default     = false
}

variable "state_admins" {
  type        = list(string)
  description = "IAM members (for example a CI identity) allowed to use the bucket and the key."
  default     = []

  validation {
    condition     = !anytrue([for m in var.state_admins : contains(["allUsers", "allAuthenticatedUsers"], m)])
    error_message = "state_admins must not contain allUsers or allAuthenticatedUsers."
  }
}

variable "noncurrent_versions_kept" {
  type        = number
  description = "Newer versions that must exist before an old version may be deleted."
  default     = 20
}

variable "noncurrent_days" {
  type        = number
  description = "Days a version must have been noncurrent before it may be deleted."
  default     = 90
}
