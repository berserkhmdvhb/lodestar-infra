# all_updates_rule is left at the provider default; the import plan decides whether it must be pinned.
resource "google_billing_budget" "this" {
  count = var.enabled ? 1 : 0

  billing_account = var.billing_account
  display_name    = var.display_name

  budget_filter {
    projects               = ["projects/${var.project_number}"]
    calendar_period        = var.calendar_period
    credit_types_treatment = var.credit_types_treatment
  }

  amount {
    specified_amount {
      currency_code = var.currency_code
      units         = var.amount_units
    }
  }

  dynamic "threshold_rules" {
    for_each = var.threshold_percents

    content {
      threshold_percent = threshold_rules.value
      spend_basis       = var.spend_basis
    }
  }
}
