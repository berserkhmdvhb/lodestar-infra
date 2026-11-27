variable "project_id" {
  type        = string
  description = "Project that holds the network."
}

variable "region" {
  type        = string
  description = "Region of the subnets, router and NAT."
  default     = "europe-west1"
}

variable "network_name" {
  type    = string
  default = "apps-vpc"
}

variable "subnet_name" {
  type    = string
  default = "apps-subnet"
}

variable "subnet_cidr" {
  type        = string
  description = "Primary range of the node subnet."
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  type        = string
  description = "Secondary range for pods."
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for services."
  default     = "10.30.0.0/20"
}

variable "router_name" {
  type    = string
  default = "apps-router"
}

variable "nat_name" {
  type    = string
  default = "apps-nat"
}

variable "enable_proxy_only_subnet" {
  type        = bool
  description = "Create the proxy-only subnet for the internal Gateway (previews)."
  default     = false
}

variable "proxy_only_subnet_name" {
  type    = string
  default = "apps-proxy-only"
}

variable "proxy_only_cidr" {
  type    = string
  default = "10.129.0.0/23"
}

variable "enable_flow_logs" {
  type        = bool
  description = "VPC flow logs on the node subnet."
  default     = true
}

variable "flow_log_aggregation_interval" {
  type    = string
  default = "INTERVAL_10_MIN"
}

variable "flow_log_sampling" {
  type        = number
  description = "Share of flows that are logged (0 to 1)."
  default     = 0.1

  validation {
    condition     = var.flow_log_sampling >= 0 && var.flow_log_sampling <= 1
    error_message = "flow_log_sampling must be between 0 and 1."
  }
}

variable "flow_log_metadata" {
  type    = string
  default = "INCLUDE_ALL_METADATA"
}
