# Mock-provider tests: no credentials, no API calls.
mock_provider "google" {}

variables {
  project_number  = "123456789012"
  billing_account = "000000-000000-000000"
}

run "disabled_by_default_creates_nothing" {
  command = plan

  assert {
    condition     = length(google_billing_budget.this) == 0
    error_message = "no budget unless enabled"
  }
}

run "enabled_budget" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition = (
      google_billing_budget.this[0].billing_account == "000000-000000-000000"
      && google_billing_budget.this[0].display_name == "Monthly budget"
      && one(google_billing_budget.this[0].budget_filter).projects == toset(["projects/123456789012"])
    )
    error_message = "billing account, name and project filter"
  }
  assert {
    condition = (
      one(one(google_billing_budget.this[0].amount).specified_amount).currency_code == "EUR"
      && one(one(google_billing_budget.this[0].amount).specified_amount).units == "20"
    )
    error_message = "amount and currency"
  }
  assert {
    condition = (
      [for t in google_billing_budget.this[0].threshold_rules : t.threshold_percent] == [0.5, 0.9, 1.0, 1.5]
      && alltrue([for t in google_billing_budget.this[0].threshold_rules : t.spend_basis == "CURRENT_SPEND"])
    )
    error_message = "four threshold rules in order with CURRENT_SPEND"
  }
}

run "enabled_requires_billing_account" {
  command = plan

  variables {
    enabled         = true
    billing_account = ""
  }

  expect_failures = [var.billing_account]
}

run "project_number_must_be_digits" {
  command = plan

  variables {
    project_number = "abc"
  }

  expect_failures = [var.project_number]
}
