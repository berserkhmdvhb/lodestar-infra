variable "project_id" {
  type        = string
  description = "Project that holds the cluster."
}

variable "network" {
  type        = string
  description = "VPC network (name or self link)."
}

variable "subnetwork" {
  type        = string
  description = "Subnetwork (name or self link) with the secondary ranges for pods and services."
}

variable "node_service_account" {
  type        = string
  description = "E-mail of the node service account (not the default compute account)."

  validation {
    condition     = !endswith(var.node_service_account, "-compute@developer.gserviceaccount.com")
    error_message = "Nodes must not run as the default compute service account; pass the dedicated node service account."
  }
}

variable "cluster_name" {
  type    = string
  default = "apps"
}

variable "location" {
  type        = string
  description = "Zone of the zonal cluster."
  default     = "europe-west1-b"
}

variable "release_channel" {
  type    = string
  default = "STABLE"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "pods_range_name" {
  type    = string
  default = "pods"
}

variable "services_range_name" {
  type    = string
  default = "services"
}

variable "enable_public_endpoint" {
  type        = bool
  description = "Keep the public IP control-plane endpoint. The DNS endpoint stays on either way."
  default     = true
}

variable "binary_authorization_mode" {
  type        = string
  description = "Binary Authorization evaluation mode; null leaves it unmanaged (off until the template's phase 11)."
  default     = null

  validation {
    condition     = var.binary_authorization_mode == null ? true : contains(["DISABLED", "PROJECT_SINGLETON_POLICY_ENFORCE"], var.binary_authorization_mode)
    error_message = "binary_authorization_mode must be null, DISABLED or PROJECT_SINGLETON_POLICY_ENFORCE."
  }
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "labels" {
  type        = map(string)
  description = "Labels for the cluster and its nodes."
  default     = { cluster = "apps" }
}

variable "maintenance_start_time" {
  type        = string
  description = "First occurrence of the recurring maintenance window (RFC 3339)."
  default     = "2026-11-21T00:00:00Z"
}

variable "maintenance_end_time" {
  type        = string
  description = "End of the first occurrence; the difference is the window length."
  default     = "2026-11-21T08:00:00Z"
}

variable "maintenance_recurrence" {
  type        = string
  description = "RFC 5545 recurrence. Saturday and Sunday weekly gives 2 x 8 h, over the 48 h per 32 days GKE requires."
  default     = "FREQ=WEEKLY;BYDAY=SA,SU"
}

variable "node_pool_name" {
  type    = string
  default = "default-pool"
}

variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "disk_type" {
  type    = string
  default = "pd-balanced"
}

variable "disk_size_gb" {
  type    = number
  default = 50
}

variable "min_node_count" {
  type    = number
  default = 1
}

variable "max_node_count" {
  type    = number
  default = 3
}

variable "spot" {
  type        = bool
  description = "Run the pool on spot VMs."
  default     = true
}

variable "enable_insecure_binding_system_unauthenticated" {
  type        = bool
  description = "Allow RBAC bindings to system:anonymous and system:unauthenticated."
  default     = false
}

variable "enable_insecure_binding_system_authenticated" {
  type        = bool
  description = "Allow RBAC bindings to system:authenticated."
  default     = false
}

variable "database_encryption_key" {
  type        = string
  description = "Cloud KMS key id for application-layer Secrets encryption; null leaves Secrets DECRYPTED."
  default     = null
}

variable "security_posture_mode" {
  type        = string
  description = "Security posture mode. BASIC is free; ENTERPRISE is paid and refused here."
  default     = "BASIC"

  validation {
    condition     = contains(["DISABLED", "BASIC"], var.security_posture_mode)
    error_message = "security_posture_mode must be DISABLED or BASIC (ENTERPRISE is paid)."
  }
}
