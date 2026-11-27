# gcp-github-wif

Keyless GitHub Actions identity: a Workload Identity pool, an OIDC provider whose attribute condition
admits only the owner ID, the repository ID and the two deploy workflows (`deploy.yml`, `deploy-ops.yml`
on `main` or a `v*` tag), and one deployer service account per environment (`gh-deployer-<env>`). Each
account may be impersonated only by the job of its own environment, and holds only the cluster-connect
role (`roles/container.clusterViewer`, or the custom role `gkeDnsConnect` with
`create_custom_connect_role = true`). No registry writer, editor or owner role is ever granted. Codifies
guide section 12.

## The subject prefix

`sub_claim_prefix` is required: it is the repository's OIDC subject prefix exactly as GitHub reports it.

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
```

Repositories created after 2026-07-15 use the immutable form `repo:<owner>@<owner_id>/<repo>@<repo_id>`;
older ones use `repo:<owner>/<repo>`. The module appends `:environment:<env>` itself, so the value must
not contain `:environment` or end with `:`. In zsh, `$VAR:environment` is mangled (`:e` is a history
modifier): write `${VAR}:environment`.

## Optional parts (off by default)

- `enable_previews`: provider `github-oidc-preview` (only `preview.yml`, environment `preview`) and the
  `gh-deployer-preview` account.
- `enable_drift`: per environment a provider `github-oidc-drift-<env>` (only `drift.yml` on `main`,
  environment `drift-<env>`) and a `gh-drift-<env>` reader holding only the connect role.

Inputs: `project_id`, `project_number`, `github_repository`, `github_owner_id`, `github_repo_id`,
`sub_claim_prefix` (all required), `environments`, `pool_id`, `pool_display_name`, `provider_id`,
`provider_display_name`, `deployer_cluster_role`, `create_custom_connect_role`, `enable_previews`,
`enable_drift`, `allowed_environment` (also pins `assertion.environment` in the main provider; default
`null`), `deployer_account_ids` (service account ID per environment; default `gh-deployer-<env>`).
The module serves one repository. For several, call it once per repository with its own `pool_id`. Some names are
project-wide, so every call in one project must follow these rules: pass `environments = ["production"]`; give each
call a unique `deployer_account_ids` entry; let at most one call set `create_custom_connect_role` (the role
`gkeDnsConnect`); keep `enable_previews` and `enable_drift` off (`gh-deployer-preview`, `gh-drift-<env>`; refused
while `allowed_environment` is set). Every deployer ID, default or given, is validated to 6 to 30 characters.
Outputs: `workload_identity_provider`, `deployer_emails`, `preview_workload_identity_provider`,
`drift_workload_identity_providers`.
