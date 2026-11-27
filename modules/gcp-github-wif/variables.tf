variable "project_id" {
  type        = string
  description = "Project that holds the pool and the service accounts."
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
  description = "The repository as owner/repo."

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo."
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
  description = "Numeric GitHub repository ID (digits only)."

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be digits only."
  }
}

variable "sub_claim_prefix" {
  type        = string
  description = "The repository's OIDC subject prefix as GitHub reports it: repo:<owner>/<repo>, or the immutable repo:<owner>@<owner_id>/<repo>@<repo_id>. Never include :environment."

  validation {
    condition     = startswith(var.sub_claim_prefix, "repo:") && !endswith(var.sub_claim_prefix, ":") && !strcontains(var.sub_claim_prefix, ":environment")
    error_message = "sub_claim_prefix must start with \"repo:\", not end with \":\" and not contain \":environment\"."
  }
}

variable "environments" {
  type        = list(string)
  description = "One deployer service account per GitHub environment."
  default     = ["dev", "qa", "production"]
}

variable "allowed_environment" {
  type        = string
  description = "When set, the main provider also admits only tokens of this GitHub environment (assertion.environment). null leaves the condition unchanged."
  default     = null

  validation {
    condition     = var.allowed_environment == null ? true : can(regex("^[A-Za-z0-9._-]+$", var.allowed_environment))
    error_message = "allowed_environment must be null or contain only letters, digits, dot, underscore and hyphen."
  }

  validation {
    condition     = var.allowed_environment == null || (!var.enable_previews && !var.enable_drift)
    error_message = "With allowed_environment set, enable_previews and enable_drift must be off: their providers admit other environment subjects into the same pool."
  }
}

variable "deployer_account_ids" {
  type        = map(string)
  description = "Deployer service account ID per environment (6 to 30 characters). An environment not listed keeps gh-deployer-<environment>."
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.deployer_account_ids) : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", id))])
    error_message = "Each deployer account ID must be 6 to 30 characters: a lowercase letter, then lowercase letters, digits or hyphens, ending in a letter or digit."
  }

  validation {
    condition     = alltrue([for e in keys(var.deployer_account_ids) : contains(var.environments, e)])
    error_message = "deployer_account_ids may only name environments listed in var.environments."
  }

  validation {
    condition     = alltrue([for e in var.environments : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", lookup(var.deployer_account_ids, e, "gh-deployer-${e}")))])
    error_message = "Every resulting deployer service account ID (given here, else gh-deployer-<environment>) must be 6 to 30 characters: lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "pool_id" {
  type        = string
  description = "ID of the workload identity pool."
  default     = "github"
}

variable "pool_display_name" {
  type        = string
  description = "Display name of the workload identity pool."
  default     = "GitHub Actions"
}

variable "provider_id" {
  type        = string
  description = "ID of the main (deployer) OIDC provider."
  default     = "github-oidc"
}

variable "provider_display_name" {
  type        = string
  description = "Display name of the main (deployer) OIDC provider."
  default     = "GitHub OIDC"
}

variable "deployer_cluster_role" {
  type        = string
  description = "Project role that lets a deployer reach the cluster. Never container.developer or container.viewer."
  default     = "roles/container.clusterViewer"
}

variable "create_custom_connect_role" {
  type        = bool
  description = "Create the custom role gkeDnsConnect (get and connect only) and use it instead of deployer_cluster_role."
  default     = false
}

variable "enable_previews" {
  type        = bool
  description = "Create the pull request preview provider and deployer."
  default     = false
}

variable "enable_drift" {
  type        = bool
  description = "Create one live-drift provider and reader per environment."
  default     = false
}
