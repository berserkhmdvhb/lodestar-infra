# user_project_override and billing_project: the Billing Budgets API refuses user credentials without both.
# The project must have serviceusage.googleapis.com enabled; bootstrap/prod does that.
provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}
