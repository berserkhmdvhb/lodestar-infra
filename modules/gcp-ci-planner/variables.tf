variable "project_id" {
  type        = string
  description = "Project that holds the pool and the planner service account."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (digits only); it appears in the principal member strings."

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be digits only."
  }
}

variable "github_repository" {
  type        = string
  description = "This repository as owner/repo."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo and use only letters, digits, dot, underscore and hyphen."
  }
}

variable "github_owner_id" {
  type        = string
  description = "Numeric GitHub owner ID (digits only)."

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be digits only."
  }
}

variable "github_repo_id" {
  type        = string
  description = "Numeric ID of this repository (digits only)."

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be digits only."
  }
}

variable "sub_claim_prefix" {
  type        = string
  description = "This repository's immutable OIDC subject prefix: repo:<owner>@<owner_id>/<repo>@<repo_id>. Never include a suffix."

  validation {
    condition     = startswith(var.sub_claim_prefix, "repo:") && !endswith(var.sub_claim_prefix, ":") && !strcontains(var.sub_claim_prefix, ":environment")
    error_message = "sub_claim_prefix must start with \"repo:\", not end with \":\" and not contain \":environment\"."
  }
}

variable "state_bucket" {
  type        = string
  description = "State bucket; the planner gets read access to its objects only."
}

variable "state_kms_key_id" {
  type        = string
  description = "Full id of the Cloud KMS key that encrypts state and plans."
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX); the planner gets roles/billing.viewer on it."
}

variable "pool_id" {
  type        = string
  description = "ID of the workload identity pool."
  default     = "github-infra"
}

variable "pool_display_name" {
  type        = string
  description = "Display name of the workload identity pool."
  default     = "GitHub Actions (infra CI)"
}

variable "provider_id" {
  type        = string
  description = "ID of the planner OIDC provider."
  default     = "lodestar-infra"
}

variable "provider_display_name" {
  type        = string
  description = "Display name of the planner OIDC provider."
  default     = "GitHub OIDC (infra CI)"
}
