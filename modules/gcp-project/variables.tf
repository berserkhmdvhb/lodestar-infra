variable "project_id" {
  type        = string
  description = "Project that gets the APIs."
}

variable "services" {
  type        = set(string)
  description = "APIs to enable (the guide's list)."
  default = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "billingbudgets.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}

variable "enable_container_audit_logs" {
  type        = bool
  description = "Data Access audit logs (ADMIN_READ and DATA_WRITE) for the container API."
  default     = true
}
