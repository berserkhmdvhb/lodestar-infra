variable "project_id" {
  type        = string
  description = "Project that holds the registry."
}

variable "region" {
  type        = string
  description = "Location of the registry repository."
  default     = "europe-west1"
}

variable "enabled" {
  type        = bool
  description = "Create the registry. Off by default: the template pushes to GHCR."
  default     = false
}

variable "repository_id" {
  type        = string
  description = "ID of the Docker repository."
  default     = "apps"
}

variable "reader_members" {
  type        = list(string)
  description = "IAM members that may pull (roles/artifactregistry.reader). No writer role is ever granted."
  default     = []

  validation {
    condition     = !anytrue([for m in var.reader_members : contains(["allUsers", "allAuthenticatedUsers"], m)])
    error_message = "reader_members must not contain allUsers or allAuthenticatedUsers."
  }
}
