# Every project-specific value is a variable without a default; the values live in the untracked terraform.tfvars.

variable "project_id" {
  type        = string
  description = "Project that holds the cluster and everything around it."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (digits only)."
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zone" {
  type        = string
  description = "Zone of the zonal cluster."
  default     = "europe-west1-b"
}

variable "github_repository" {
  type        = string
  description = "The repository as owner/repo."
}

variable "github_owner_id" {
  type        = string
  description = "Numeric GitHub owner ID (digits only)."
}

variable "github_repo_id" {
  type        = string
  description = "Numeric GitHub repository ID (digits only)."
}

variable "sub_claim_prefix" {
  type        = string
  description = "The repository's OIDC subject prefix as GitHub reports it (repo:<owner>/<repo>, or the immutable form with IDs)."
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX)."
}

variable "budget_display_name" {
  type        = string
  description = "Display name of the existing budget, as the live budget has it."
}

variable "budget_id" {
  type        = string
  description = "ID of the existing budget (the last part of its name); used only to import it."
}

variable "state_bucket" {
  type        = string
  description = "State bucket created by bootstrap/."
}

variable "state_prefix" {
  type    = string
  default = "envs/apps"
}

variable "state_kms_key_id" {
  type        = string
  description = "Full id of the Cloud KMS key that encrypts state and plans (bootstrap/ output kms_key_id)."
}

variable "ci_github_repository" {
  type        = string
  description = "This infrastructure repository as owner/repo (the CI planner identity is limited to it)."
}

variable "ci_github_repo_id" {
  type        = string
  description = "Numeric ID of this infrastructure repository (digits only)."
}

variable "ci_sub_claim_prefix" {
  type        = string
  description = "This repository's immutable OIDC subject prefix: repo:<owner>@<owner_id>/<repo>@<repo_id>."
}
