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
  type        = string
  description = "Name of the GKE cluster."
  default     = "apps"
}

variable "location" {
  type        = string
  description = "Zone (zonal cluster) or region (regional cluster) of the cluster and its node pool."
  default     = "europe-west1-b"
}

variable "release_channel" {
  type        = string
  description = "GKE release channel (RAPID, REGULAR, STABLE or EXTENDED)."
  default     = "STABLE"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "pods_range_name" {
  type        = string
  description = "Name of the subnet secondary range used for pods."
  default     = "pods"
}

variable "services_range_name" {
  type        = string
  description = "Name of the subnet secondary range used for services."
  default     = "services"
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
  type        = bool
  description = "Whether the cluster refuses deletion."
  default     = true
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

  # A 32-day span holds at least 4 of each weekday: days x hours x 4 must reach 48. Checked for FREQ=WEEKLY;BYDAY=... only.
  validation {
    condition = !startswith(var.maintenance_recurrence, "FREQ=WEEKLY;BYDAY=") ? true : (
      length(split(",", trimprefix(var.maintenance_recurrence, "FREQ=WEEKLY;BYDAY=")))
      * try(one([for h in range(1, 25) : h if timecmp(timeadd(var.maintenance_start_time, "${h}h"), var.maintenance_end_time) == 0]), 0)
      >= 12
    )
    error_message = "The weekly window must total at least 48 hours in 32 days: number of days x window hours (whole hours, up to 24) must be at least 12."
  }
}

variable "node_pool_name" {
  type        = string
  description = "Name of the node pool."
  default     = "default-pool"
}

variable "machine_type" {
  type        = string
  description = "Compute machine type of the nodes."
  default     = "e2-standard-2"
}

variable "disk_type" {
  type        = string
  description = "Boot disk type of the nodes."
  default     = "pd-balanced"
}

variable "disk_size_gb" {
  type        = number
  description = "Boot disk size of each node, in GB."
  default     = 50
}

variable "min_node_count" {
  type        = number
  description = "Minimum node count of the node pool autoscaler."
  default     = 1
}

variable "max_node_count" {
  type        = number
  description = "Maximum node count of the node pool autoscaler."
  default     = 3
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

variable "node_locations" {
  type        = list(string)
  description = "Zones of the node pool (and the cluster) for a regional location; null keeps the provider default."
  default     = null
}

variable "location_policy" {
  type        = string
  description = "Autoscaler location policy: ANY (suits spot) or BALANCED (spreads on-demand nodes across zones)."
  default     = "ANY"

  validation {
    condition     = contains(["ANY", "BALANCED"], var.location_policy)
    error_message = "location_policy must be ANY or BALANCED."
  }
}

variable "total_max_node_count" {
  type        = number
  description = "Total maximum node count across all zones. When set it replaces the per-zone maximum, and min_node_count becomes the total minimum (the provider forbids both kinds of limit together)."
  default     = null
}

variable "oauth_scopes" {
  type        = list(string)
  description = "OAuth scopes of the node pool."
  default = [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
  ]
}
