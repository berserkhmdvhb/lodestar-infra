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

variable "service_name" {
  type        = string
  description = "Service name; namespaces are <service>-<env> and <service>-<env>-db."
  default     = "your-service-name"
}

variable "app_environments" {
  type        = list(string)
  description = "Environments whose app namespace may read <service>-<env>-* secrets."
  default     = ["dev", "qa", "production"]
}

variable "db_environments" {
  type        = list(string)
  description = "Environments whose db namespace may read the <service>-<env>-db-password secret."
  default     = ["dev", "qa"]
}

variable "secret_keys" {
  type        = map(list(string))
  description = "Per environment, the keys of the empty secrets to create (secret id <service>-<env>-<key>). Add production's db-user and db-password here once Cloud SQL exists."
  default = {
    dev        = ["db-user", "db-password", "stats-pass"]
    qa         = ["db-user", "db-password", "stats-pass"]
    production = ["stats-pass"]
  }
}
