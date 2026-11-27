# gcp-project

Enables the Google Cloud APIs the platform needs, one `google_project_service` each, with
`disable_on_destroy = false` and `disable_dependent_services = false`. Codifies the guide's API step.

Inputs: `project_id` (required), `services` (default: the nine APIs of the guide).
Outputs: `services`.
