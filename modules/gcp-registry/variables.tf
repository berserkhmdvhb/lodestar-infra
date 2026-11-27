variable "project_id" {
  type        = string
  description = "Project that holds the registry."
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "enabled" {
  type        = bool
  description = "Create the registry. Off by default: the template pushes to GHCR."
  default     = false
}

variable "repository_id" {
  type    = string
  default = "apps"
}

variable "reader_members" {
  type        = list(string)
  description = "IAM members that may pull (roles/artifactregistry.reader). No writer role is ever granted."
  default     = []
}
