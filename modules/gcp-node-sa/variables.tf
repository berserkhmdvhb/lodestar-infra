variable "project_id" {
  type        = string
  description = "Project that holds the service account and receives the roles."
}

variable "account_id" {
  type    = string
  default = "gke-nodes"
}

variable "display_name" {
  type    = string
  default = "GKE nodes (apps)"
}

variable "use_default_node_role" {
  type        = bool
  description = "true: roles/container.defaultNodeServiceAccount only. false: the four classic node roles."
  default     = true
}
