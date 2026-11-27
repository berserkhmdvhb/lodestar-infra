variable "project_id" {
  type        = string
  description = "Project that holds the secrets and the workload identity pool (<project_id>.svc.id.goog)."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (digits only); it appears in the member strings and the conditions."

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be digits only."
  }
}

variable "region" {
  type        = string
  description = "The single replica location of every secret."
  default     = "europe-west1"
}

variable "secrets" {
  type        = map(object({ namespace = string }))
  description = "Platform secrets by secret id. The external-secrets service account in the given namespace may read only that secret."

  validation {
    condition     = alltrue([for id, s in var.secrets : can(regex("^[a-zA-Z0-9_-]+$", id)) && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", s.namespace)) && length(s.namespace) <= 63])
    error_message = "secret ids use letters, digits, - and _; namespaces are DNS labels (at most 63 characters)."
  }
}
