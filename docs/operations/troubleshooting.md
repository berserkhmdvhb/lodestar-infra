# Operations: troubleshooting

Part of the [operations runbook](README.md). Section numbers are the runbook's original ones, so references such as "section 5.1" keep working; the index maps each to its file.

## 14. Troubleshooting index

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `apt update` warns the Google Cloud SDK source is configured multiple times | two files in `/etc/apt/sources.list.d/` name the same repository | keep one file; see 1.1 |
| `gh auth login` ends with no token, or waits forever | the device flow was not completed: the one-time code must be entered in the browser at the printed URL, before it expires | rerun `gh auth login`; open the URL, type the code, approve; check with `gh auth status` |
| `wget: bad port '8080;'` in the NetworkPolicy probe | the `;` of `...:8080; echo "exit=$?"` reached `wget` as part of the URL | put `printf 'exit=%s\n' "$?"` on its own line (5.4) |
| `kubectl apply --dry-run=server` says `NotFound` | the dry run creates nothing, so the namespaces do not exist | apply only the `Namespace` documents first with `yq` (7.2) |
| a deploy with the in-cluster database is refused: CronJob name too long (over 52 characters) | the chart's `<fullname>-pg-backup-verify` has no length guard (open template bug); a long release name makes the fullname long | use a shorter `SERVICE_NAME`; if namespaces already exist, delete the empty ones and re-render (7.5) |
| `github-settings.sh --apply` stops with `HTTP 422 ... Actor ... integration must be part of the ruleset source` | the release GitHub App is not installed on the repository, so the `release-tags` ruleset cannot name it | install the App on the repository, then rerun `--apply` (9.3); it updates in place |
| `ls ~/Downloads/*.pem` or `gh secret set ... < file`: "No such file" / not found | the key was not generated, is in another folder, a placeholder `<the-file>` was typed literally, a glob matched nothing or several files, or `GH_REPO` names the wrong repository | generate a key on the App's page (Credentials, Key pairs); list `ls ~/Downloads/*.pem`; use the exact name; check `printf '%s\n' "${GH_REPO}"` (9.5) |
| deploy-ops `check` fails: `Permission 'iam.serviceAccounts.getAccessToken' denied` | **cause 1:** the `workloadIdentityUser` member uses the classic subject (`repo:<owner>/<repo>:environment:<env>`), but the repository has immutable subjects | derive `SUB_PREFIX` from the API and rebind (6.2, 6.7); once section 11 is done these bindings are managed by OpenTofu (`gcp-github-wif`, `sub_claim_prefix`), so fix the value and apply a reviewed plan, never by hand |
| | **cause 2:** zsh turned `$GH_REPO:environment:$env` into `repo:nvironment:<env>` (and an unbraced repair into `nvironment:<env>`), members that match nothing | brace every variable before a colon, rebind and remove the bad members (6.7); after section 11, through the code and a plan |
| | **cause 3:** the binding is right but has not propagated yet | wait up to about 7 minutes after the change and rerun (6.6) |
| `gcloud` / `tofu` plan: `403 ... serviceusage.googleapis.com ... SERVICE_DISABLED` | the Service Usage API is not enabled in the project, and the root bills requests to the project, so the `google_project_service` reads fail | the bootstrap apply was skipped or has not propagated: wait 2 to 3 minutes; only for an old bootstrap, add the API through it (11.4) |
| apply or plan: `SERVICE_DISABLED` for `cloudbilling.googleapis.com` on a billing-account IAM member | `user_project_override` bills requests to the project, so the Cloud Billing API must be enabled there | the `ci_planner` module enables it; if it was just enabled, wait 2 to 3 minutes and plan again |
| plan: `Attribute redefined` for `ci_github_repository`, `ci_github_repo_id` or `ci_sub_claim_prefix` | the tfvars append of the CI identity runbook was run twice, so each key is in `terraform.tfvars` twice | keep the first occurrence of each key with the `awk` repair of 12.4, then `tofu fmt envs/apps/terraform.tfvars`; the append is now guarded and safe to repeat |
| `tofu apply <file>`: no such file / "Failed to load" a plan | the saved plan was already deleted (`rm -f` after use), or was run from the wrong directory (the file is in `bootstrap/` or `envs/apps/`) | plan again into a new file; use `tofu -chdir=<root> apply <file>` |
| `Excess arguments.`, `command not found: <word>`, or an odd error after a paste | prose (a sentence, a heading, a `->` explanation) was copied into the shell together with the commands | copy only the code block; if a prose line ran, check its side effects before going on |
| `unrecognized arguments` / flag unknown in `gcloud container clusters create` | an old gcloud | update gcloud and rerun 5.1 |
| `Maintenance policy would go longer than 32d without 48h maintenance availability` | the maintenance window is too short | use the Saturday and Sunday 8-hour window of 5.2 |
| `ImagePullBackOff` for a public image | no outbound route: NAT is missing or in another region | recheck section 3 |
| a workflow login is refused: `The given credential is rejected by the attribute condition` | wrong owner ID, repository ID, repository name case, or a workflow file or ref the condition does not allow | compare with `providers describe`. Before section 11: `providers update-oidc --attribute-condition=...` (6.3). After it the provider is managed by OpenTofu (`gcp-github-wif`): change the code and apply a reviewed plan, not by hand |
| `kubectl` hangs or times out | wrong kubeconfig, or the node pool is scaled to 0 | `source ~/gke-setup.env`; `kubectl config current-context`; check the node count |
| `tofu` reports an authentication or quota-project error | the ADC login expired or has no quota project | repeat 2.5 |
| zsh: `bad pattern` / `command not found: #` on a comment | interactive zsh does not ignore `#` comments by default | `setopt interactive_comments`, or paste without the comments |
| `GraphQL: Could not resolve to a PullRequest with the number of N`, or `gh` acting on the wrong repository | `GH_REPO` from `~/gke-setup.env` names the template repository, and `gh` prefers it to the current directory | `unset GH_REPO`, or add `-R "<owner>/lodestar-infra"` to the command |

