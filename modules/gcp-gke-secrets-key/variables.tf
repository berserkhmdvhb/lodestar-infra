variable "project_id" {
  type        = string
  description = "Project that holds the key."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (digits only); names the GKE service agent."

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be digits only."
  }
}

variable "region" {
  type        = string
  description = "Region of the key ring: the cluster's region (a zonal cluster in europe-west1-b is in europe-west1)."
  default     = "europe-west1"
}

variable "key_ring_name" {
  type    = string
  default = "gke"
}

variable "key_name" {
  type    = string
  default = "secrets"
}

variable "rotation_period" {
  type        = string
  description = "Rotation period in seconds (default 90 days)."
  default     = "7776000s"
}
