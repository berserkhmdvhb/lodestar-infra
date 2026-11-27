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
