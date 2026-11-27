# Every project-specific value is a variable without a default; the values live in the untracked terraform.tfvars.

variable "project_id" {
  type        = string
  description = "The production project that holds the cluster and everything around it."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (digits only)."
}

variable "region" {
  type        = string
  description = "Region of the provider, the network and the regional cluster."
  default     = "europe-west1"
}

variable "node_locations" {
  type        = list(string)
  description = "Zones of the node pool."
  default     = ["europe-west1-b", "europe-west1-c"]
}

variable "services" {
  type = map(object({
    service_name        = string
    github_repository   = string
    github_owner_id     = string
    github_repo_id      = string
    sub_claim_prefix    = string
    deployer_account_id = string
    secret_keys         = list(string)
  }))
  description = "One entry per service hosted in production, by a short key. service_name is the namespace prefix (<service_name>-production); deployer_account_id is the deployer service account ID (6 to 30 characters); secret_keys are that service's production secret keys."

  validation {
    condition     = length(var.services) > 0
    error_message = "services must name at least one service."
  }

  validation {
    condition     = alltrue([for k in keys(var.services) : can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", k))])
    error_message = "Service keys are 3 to 20 characters: lowercase letters, digits and hyphens, starting with a letter (they build the pool ID gh-<key>)."
  }

  validation {
    condition     = alltrue([for s in values(var.services) : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", s.deployer_account_id))])
    error_message = "deployer_account_id must be 6 to 30 characters: a lowercase letter, then lowercase letters, digits or hyphens, ending in a letter or digit."
  }

  validation {
    condition     = length(distinct([for s in values(var.services) : s.deployer_account_id])) == length(var.services)
    error_message = "deployer_account_id must be unique per service."
  }

  validation {
    condition = alltrue([for s in values(var.services) :
      s.sub_claim_prefix == try("repo:${split("/", s.github_repository)[0]}@${s.github_owner_id}/${split("/", s.github_repository)[1]}@${s.github_repo_id}", "")
    ])
    error_message = "sub_claim_prefix must be repo:<owner>@<owner_id>/<repo>@<repo_id>, built from the same entry's github_repository, github_owner_id and github_repo_id."
  }

  validation {
    condition     = length(distinct([for s in values(var.services) : s.service_name])) == length(var.services)
    error_message = "service_name must be unique per service."
  }
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX)."
}

variable "budget_display_name" {
  type        = string
  description = "Display name of the production budget."
  default     = "Production monthly budget"
}

variable "state_bucket" {
  type        = string
  description = "Production state bucket (bootstrap/prod output state_bucket)."
}

variable "state_prefix" {
  type        = string
  description = "Prefix (folder) of this root's state inside the state bucket."
  default     = "envs/prod"
}

variable "state_kms_key_id" {
  type        = string
  description = "Full id of the Cloud KMS key that encrypts state and plans (bootstrap/prod output kms_key_id)."
}

variable "ci_github_repository" {
  type        = string
  description = "This infrastructure repository as owner/repo (the CI planner identity is limited to it)."
}

variable "ci_github_owner_id" {
  type        = string
  description = "Numeric GitHub owner ID of this infrastructure repository (digits only)."
}

variable "ci_github_repo_id" {
  type        = string
  description = "Numeric ID of this infrastructure repository (digits only)."
}

variable "ci_sub_claim_prefix" {
  type        = string
  description = "This repository's immutable OIDC subject prefix: repo:<owner>@<owner_id>/<repo>@<repo_id>."
  validation {
    condition     = var.ci_sub_claim_prefix == try("repo:${split("/", var.ci_github_repository)[0]}@${var.ci_github_owner_id}/${split("/", var.ci_github_repository)[1]}@${var.ci_github_repo_id}", "")
    error_message = "ci_sub_claim_prefix must be repo:<owner>@<owner_id>/<repo>@<repo_id>, built from ci_github_repository, ci_github_owner_id and ci_github_repo_id."
  }
}
