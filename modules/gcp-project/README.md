# gcp-project

Enables the Google Cloud APIs the platform needs, one `google_project_service` each, with
`disable_on_destroy = false` and `disable_dependent_services = false`. Codifies the guide's API step.

It also sets the Data Access audit config for `container.googleapis.com` with `ADMIN_READ` and `DATA_WRITE`
only; reads of Kubernetes objects (every get, list and watch) are not logged, so Logging's free tier is
not flooded. Writes to Kubernetes objects are already in the always-on, free Admin Activity logs. The
resource is authoritative for that one service only. It lives here because it is project-level IAM
policy next to the project's APIs; a module of its own for one resource would add nothing.

Inputs: `project_id` (required), `services` (default: the nine APIs of the guide),
`enable_container_audit_logs` (default true).
Outputs: `services`.

## What happens to an API on destroy

A plan shows `deletion_policy = "DELETE"` on every `google_project_service`. That is the provider's default and it
does not mean the API is switched off. Read from the source of provider `hashicorp/google` v8.12.0
(`google/services/resourcemanager/resource_google_project_service.go` and `google/tpgresource/utils.go`):

- `deletion_policy` only decides whether a destroy may proceed: `PREVENT` makes it fail, `ABANDON` drops the
  resource from state and calls nothing, `DELETE` (the default) lets the delete function run.
- The delete function then reads `disable_on_destroy`. When it is false the provider logs "skip disabling service",
  removes the resource from state, and never calls the Service Usage API. Only when it is true does it disable the
  API (with `disable_dependent_services` deciding about dependent APIs).
- So `disable_on_destroy = false` is what keeps the API enabled; `deletion_policy = "DELETE"` is harmless next to it.
  This module, `gcp-ci-planner` and the bootstrap all set `disable_on_destroy = false` explicitly. In that source the
  attribute has no schema default, so an unset value also reads as false; do not rely on it, the explicit value is
  what the tests and this note assume.
- Setting `deletion_policy = "ABANDON"` as well would add nothing, and `"PREVENT"` would block removing a service
  from `services`. No code was changed for this note.
