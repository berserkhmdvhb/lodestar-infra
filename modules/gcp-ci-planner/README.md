# gcp-ci-planner

A read-only, keyless identity for this repository's CI: pull request plans and the weekly drift run
(`plan.yml`, `drift.yml`). It is separate from the pool of `gcp-github-wif` (which trusts only the
application deploy workflows) and creates its own pool (`github-infra`) and provider (`lodestar-infra`).

- The provider condition admits only the owner ID, this repository's ID, the events `pull_request`,
  `schedule` and `workflow_dispatch`, and the workflow refs `plan.yml` and `drift.yml` on `main` or a pull
  request merge ref. The repository name is regex-escaped.
- The service account `tofu-planner` may be impersonated by exactly two subjects, built from the immutable
  `sub_claim_prefix` (`repo:<owner>@<owner_id>/<repo>@<repo_id>`): `<prefix>:pull_request` and
  `<prefix>:ref:refs/heads/main`. The jobs must not use GitHub environments.
- Roles: `roles/viewer`, `roles/iam.securityReviewer` and `roles/serviceusage.serviceUsageConsumer` on the
  project (the last because requests are billed to the project); `roles/storage.objectViewer` on the state
  bucket only; `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the state key only (the `gcp_kms` key provider
  calls Encrypt as well as Decrypt); `roles/billing.viewer` on the billing account, which includes cost data
  (custom billing roles need an organization). Nothing writes; a test fails on any write or admin role.

Inputs: `project_id`, `project_number`, `github_repository`, `github_owner_id`, `github_repo_id`,
`sub_claim_prefix`, `state_bucket`, `state_kms_key_id`, `billing_account` (all required), `pool_id`,
`provider_id` and display names. Outputs: `ci_workload_identity_provider`, `ci_service_account`.
