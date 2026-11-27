variable "enabled" {
  type        = bool
  description = "Create the budget. Off by default; the root turns it on."
  default     = false
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). Required when enabled; keep it in untracked tfvars, never in Git."
  default     = ""

  validation {
    condition     = !var.enabled || var.billing_account != ""
    error_message = "billing_account is required when enabled."
  }
}

variable "project_number" {
  type        = string
  description = "Numeric number of the project the budget is filtered to (digits only)."

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be digits only."
  }
}

variable "display_name" {
  type        = string
  description = "Budget name; the live name goes in untracked tfvars."
  default     = "Monthly budget"
}

variable "calendar_period" {
  type    = string
  default = "MONTH"
}

variable "credit_types_treatment" {
  type    = string
  default = "INCLUDE_ALL_CREDITS"
}

variable "currency_code" {
  type    = string
  default = "EUR"
}

variable "amount_units" {
  type        = string
  description = "Whole units of the monthly amount."
  default     = "20"
}

variable "threshold_percents" {
  type        = list(number)
  description = "Alert thresholds as fractions of the amount, in order."
  default     = [0.5, 0.9, 1.0, 1.5]
}

variable "spend_basis" {
  type    = string
  default = "CURRENT_SPEND"
}
