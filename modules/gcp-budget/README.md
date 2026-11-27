# gcp-budget

An optional monthly budget for one project (guide section 4). Off by default (`enabled = false`); the root
turns it on. It creates a `google_billing_budget` filtered to `projects/<project_number>`, a specified
amount (default 20 EUR) and one alert threshold per entry of `threshold_percents` (default 50%, 90%,
100%, 150% of `CURRENT_SPEND`).

`billing_account` is required when enabled. It never goes into Git: put it in an untracked `*.tfvars`.

`calendar_period`, the credit types and `all_updates_rule` are left unset (provider defaults). The owner's
import plan decides whether any of them must be pinned to match the live budget.

## Provider requirement

With user credentials the Billing Budgets API refuses the call unless the google provider sets
`user_project_override = true` and `billing_project = "<project>"`. Set both in the root (L1.5).

Inputs: `project_number` (required), `enabled`, `billing_account`, `display_name`, `currency_code`,
`amount_units`, `threshold_percents`, `spend_basis`.
Outputs: `budget_name`.
